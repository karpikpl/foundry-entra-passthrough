from __future__ import annotations

import base64
import json
import os
import webbrowser
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import anyio
import click
from dotenv import load_dotenv
from fastmcp import Client
from fastmcp.client.auth import OAuth

ENV_FILE = Path(__file__).with_name(".env")
load_dotenv(ENV_FILE)

VSCODE_CLIENT_ID = "aebc6443-996d-45c2-90f0-388ff96faa56"
HELLO_TOOL_CANDIDATES = ("hello_world", "hello")


def _first_env(*names: str) -> str | None:
    for name in names:
        value = os.environ.get(name)
        if value:
            return value
    return None


def _normalize_server_url(server_url: str) -> str:
    parsed = urlparse(server_url)
    if not parsed.path or parsed.path == "/":
        return server_url.rstrip("/") + "/mcp"
    return server_url.rstrip("/")


def _resolve_config(
    server_url: str | None,
    client_id: str | None,
    server_client_id: str | None,
    scope: str | None,
) -> dict[str, str]:
    resolved_server_url = server_url or _first_env(
        "DIRECT_SERVER_URL",
        "SERVER_URL",
        "FIXED_SERVER_URL",
        "REPRO_SERVER_URL",
    )
    if not resolved_server_url:
        raise click.ClickException(
            "Missing server URL. Set DIRECT_SERVER_URL or pass --server-url."
        )

    resolved_server_client_id = server_client_id or _first_env(
        "AZURE_CLIENT_ID",
        "SERVER_CLIENT_ID",
        "CLIENT_ID",
        "FIXED_CLIENT_ID",
        "REPRO_CLIENT_ID",
    )
    resolved_scope = scope or _first_env("DIRECT_SCOPE", "MCP_SCOPE")
    if not resolved_scope:
        if not resolved_server_client_id:
            raise click.ClickException(
                "Missing server client ID. Set AZURE_CLIENT_ID/SERVER_CLIENT_ID "
                "or pass --server-client-id so the default scope can be built."
            )
        resolved_scope = f"api://{resolved_server_client_id}/mcp.access"

    resolved_client_id = (
        client_id
        or _first_env("TEST_CLIENT_ID", "DIRECT_CLIENT_ID", "VSCODE_CLIENT_ID")
        or VSCODE_CLIENT_ID
    )

    return {
        "server_url": _normalize_server_url(resolved_server_url),
        "client_id": resolved_client_id,
        "scope": resolved_scope,
        "server_client_id": resolved_server_client_id or "",
    }


def _decode_jwt_payload(token: str) -> dict[str, Any]:
    try:
        payload_b64 = token.split(".")[1]
        payload_b64 += "=" * (-len(payload_b64) % 4)
        return json.loads(base64.urlsafe_b64decode(payload_b64))
    except Exception:
        return {}


class _OAuth(OAuth):
    """OAuth with a terminal-friendly URL display and optional browser launch."""

    def __init__(self, *args: Any, open_browser: bool = True, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self._open_browser = open_browser

    async def redirect_handler(self, authorization_url: str) -> None:
        click.echo("\n" + "─" * 60)
        click.echo("Open this URL to authenticate:")
        click.echo(authorization_url)
        click.echo("─" * 60 + "\n")
        if self._open_browser:
            webbrowser.open(authorization_url)


async def _call_hello_tool(client: Client, tool_names: list[str]) -> tuple[str | None, str | None]:
    for tool_name in HELLO_TOOL_CANDIDATES:
        if tool_name in tool_names:
            call_result = await client.call_tool(tool_name, {"name": "World"})
            result_text = call_result.content[0].text if call_result.content else None
            return tool_name, result_text
    return None, None


async def _run_flow(
    config: dict[str, str], open_browser: bool
) -> tuple[list[str], str | None, str | None, dict[str, Any]]:
    # Direct Entra validation must use a pre-registered client ID. Supplying
    # client_id here forces FastMCP's OAuth helper to skip Dynamic Client Registration.
    oauth = _OAuth(
        scopes=[config["scope"]],
        client_name="MCP Direct Entra Test Client",
        client_id=config["client_id"],
        open_browser=open_browser,
    )

    async with Client(config["server_url"], auth=oauth) as client:
        tools = await client.list_tools()
        tool_names = [tool.name for tool in tools]
        called_tool, tool_result = await _call_hello_tool(client, tool_names)
        tokens = await oauth.token_storage_adapter.get_tokens()
        claims = _decode_jwt_payload(tokens.access_token) if tokens else {}
        if tokens and tokens.scope and "scp" not in claims:
            claims["scp"] = tokens.scope
        return tool_names, called_tool, tool_result, claims


def _claim_value(claims: dict[str, Any], *keys: str) -> Any:
    for key in keys:
        value = claims.get(key)
        if value not in (None, "", []):
            return value
    return "<missing>"


def _format_claims(claims: dict[str, Any]) -> str:
    if not claims:
        return "No access token claims captured."

    rows = [
        ("aud", _claim_value(claims, "aud")),
        ("azp/appid", _claim_value(claims, "azp", "appid")),
        ("scope", _claim_value(claims, "scp")),
        ("name", _claim_value(claims, "name")),
        ("upn", _claim_value(claims, "preferred_username", "upn")),
        ("oid", _claim_value(claims, "oid")),
        ("tid", _claim_value(claims, "tid")),
    ]
    return "\n".join(f"  {label:10} {value}" for label, value in rows)


def run_flow(
    server_url: str | None,
    client_id: str | None,
    server_client_id: str | None,
    scope: str | None,
    open_browser: bool,
) -> None:
    config = _resolve_config(server_url, client_id, server_client_id, scope)

    click.echo(f"Server URL: {config['server_url']}")
    click.echo(f"Public client ID: {config['client_id']}")
    click.echo(f"Requested scope: {config['scope']}")

    try:
        tool_names, called_tool, tool_result, claims = anyio.run(
            _run_flow, config, open_browser
        )
    except Exception as exc:
        raise click.ClickException(str(exc)) from exc

    click.echo(
        f"\n✅ Direct Entra flow succeeded: tools/list returned {len(tool_names)} tool(s): {tool_names}"
    )
    click.echo("\n--- Token claims ---")
    click.echo(_format_claims(claims))
    click.echo("--------------------")

    if called_tool and tool_result:
        click.echo(f"\n--- Tool result ({called_tool}) ---")
        click.echo(tool_result)
        click.echo("-------------------------------")
    else:
        click.echo(
            "\n⚠️  No hello tool was exposed. The auth flow still succeeded, but "
            "the server did not publish hello_world/hello for the end-to-end check."
        )


COMMON_OPTIONS = [
    click.option(
        "--server-url",
        help="MCP endpoint URL (for example https://example.azurewebsites.net/mcp).",
    ),
    click.option(
        "--client-id",
        help=(
            "Pre-registered public client ID. Defaults to TEST_CLIENT_ID or VS Code's "
            f"client ID ({VSCODE_CLIENT_ID})."
        ),
    ),
    click.option(
        "--server-client-id",
        help="Resource app registration client ID used to derive the default scope.",
    ),
    click.option(
        "--scope",
        help="Scope to request. Defaults to api://{server-client-id}/mcp.access.",
    ),
    click.option(
        "--open-browser/--no-open-browser",
        default=True,
        show_default=True,
        help="Open the authorization URL in a browser automatically.",
    ),
]


def apply_common_options(func):
    for option in reversed(COMMON_OPTIONS):
        func = option(func)
    return func


@click.group()
def cli() -> None:
    """Local MCP direct-Entra test client — PKCE auth code, no DCR."""


@cli.command()
@apply_common_options
def direct(
    server_url: str | None,
    client_id: str | None,
    server_client_id: str | None,
    scope: str | None,
    open_browser: bool,
) -> None:
    """Run the direct-Entra happy path: PKCE auth code → token → MCP tool call."""
    run_flow(server_url, client_id, server_client_id, scope, open_browser)


@cli.command("fetch-token")
@apply_common_options
def fetch_token(
    server_url: str | None,
    client_id: str | None,
    server_client_id: str | None,
    scope: str | None,
    open_browser: bool,
) -> None:
    """Alias for direct; retained for QA scripts and manual verification."""
    run_flow(server_url, client_id, server_client_id, scope, open_browser)


if __name__ == "__main__":
    cli()
