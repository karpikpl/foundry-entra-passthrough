from __future__ import annotations

import os
from pathlib import Path
from typing import Any

import anyio
import click
from dotenv import load_dotenv

# fastmcp's Client handles MCP protocol; OAuth handles the full OAuth 2.1
# PKCE flow including DCR, browser redirect, callback, and token storage.
# This replaces ~300 lines of manual PKCE implementation that was here before.
import webbrowser

from fastmcp import Client
from fastmcp.client.auth import BearerAuth, OAuth

ENV_FILE = Path(__file__).with_name(".env")
load_dotenv(ENV_FILE)


def _require_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise click.ClickException(
            f"Missing required environment variable '{name}'. "
            f"Run 'azd provision' or populate client/.env."
        )
    return value


def get_config(mode: str) -> dict[str, Any]:
    if mode == "repro":
        return {
            "server_url": _require_env("REPRO_SERVER_URL"),
            "client_id": _require_env("REPRO_CLIENT_ID"),
            "audience": _require_env("REPRO_AUDIENCE"),
            "expect_success": False,
        }
    if mode == "fixed":
        return {
            "server_url": _require_env("FIXED_SERVER_URL"),
            "client_id": _require_env("FIXED_CLIENT_ID"),
            "audience": _require_env("FIXED_AUDIENCE"),
            "expect_success": True,
        }
    raise ValueError(f"Unknown mode: {mode}")


class _OAuth(OAuth):
    """OAuth with a terminal-friendly URL display.

    The base class logs the auth URL via logger.info(), which wraps at the
    terminal column width and makes the URL impossible to click or copy.
    Override redirect_handler to print it on a single clearly-delimited line.
    """

    async def redirect_handler(self, authorization_url: str) -> None:
        click.echo("\n" + "─" * 60)
        click.echo("Open this URL to authenticate:")
        click.echo(authorization_url)
        click.echo("─" * 60 + "\n")
        webbrowser.open(authorization_url)


def run_flow(mode: str, server_url: str, audience: str, open_browser: bool) -> None:
    # OAuth() discovers /.well-known/oauth-protected-resource from server_url,
    # finds our OAuthProxy's /auth/* endpoints (NOT login.microsoftonline.com),
    # does DCR + PKCE, opens a browser, handles the callback, and stores the token.
    # The proxy then exchanges with Entra internally and issues a FastMCP JWT.
    #
    # Only request the custom mcp.access scope — do NOT include openid/offline_access
    # alongside a custom api:// scope. Entra assigns those OIDC scopes to a different
    # internal SP, creating split consent that breaks the token exchange.
    config = get_config(mode)

    # The repro server uses direct Entra (RS-mode) with no OAuthProxy, so there is no
    # /auth/register endpoint — Entra does not support Dynamic Client Registration.
    # Pass the pre-registered client_id so FastMCP skips DCR entirely.
    oauth = _OAuth(
        scopes=[f"{audience}/mcp.access"],
        client_name="MCP OAuth Test Client",
        client_id=config.get("client_id"),
    )

    async def _run() -> tuple[list, str | None]:
        async with Client(server_url, auth=oauth) as client:
            tools = await client.list_tools()
            result = None
            if any(t.name == "hello" for t in tools):
                call_result = await client.call_tool("hello", {"name": "World"})
                result = call_result.content[0].text if call_result.content else None
            return tools, result

    try:
        tools, tool_result = anyio.run(_run)
        tool_names = [t.name for t in tools]
        if config["expect_success"]:
            click.echo(
                f"✅ FIX CONFIRMED: tools/list returned {len(tools)} tool(s): {tool_names}"
            )
            if tool_result:
                click.echo("\n--- Tool result (hello) ---")
                click.echo(tool_result)
                click.echo("---------------------------")
        else:
            click.echo(
                f"⚠️  REPRO server unexpectedly succeeded: {tool_names}"
            )
    except Exception as exc:
        if not config["expect_success"]:
            click.echo(f"❌ REPRO CONFIRMED: {exc}", err=True)
        else:
            raise click.ClickException(str(exc)) from exc


COMMON_OPTIONS = [
    click.option(
        "--server-url",
        help="Override the default server URL for the selected environment.",
    ),
    click.option(
        "--audience",
        help="Override the default audience prefix (e.g. api://your-app-id-uri).",
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
    """Local MCP OAuth test client — uses fastmcp Client + OAuth helper."""


@cli.command()
@apply_common_options
def repro(server_url: str | None, audience: str | None, open_browser: bool) -> None:
    """Test the repro server (direct Entra, expected to fail in VS Code)."""
    config = get_config("repro")
    run_flow(
        mode="repro",
        server_url=server_url or config["server_url"],
        audience=audience or config["audience"],
        open_browser=open_browser,
    )


@cli.command()
@apply_common_options
def fixed(server_url: str | None, audience: str | None, open_browser: bool) -> None:
    """Test the fixed server (OAuthProxy — should succeed end-to-end)."""
    config = get_config("fixed")
    run_flow(
        mode="fixed",
        server_url=server_url or config["server_url"],
        audience=audience or config["audience"],
        open_browser=open_browser,
    )


@cli.command("fetch-token")
@apply_common_options
@click.argument("mode", type=click.Choice(["fixed", "repro"]))
def fetch_token(
    mode: str, server_url: str | None, audience: str | None, open_browser: bool
) -> None:
    """Verify OAuth flow end-to-end and report success.

    With OAuthProxy the server accepts FastMCP JWTs (not raw Entra tokens),
    so the old 'paste token into VS Code inputs' workaround is no longer needed
    — VS Code authenticates directly against the proxy.  This command just
    confirms the full flow works from the command line.

    Example:
        uv run python test_client.py fetch-token fixed
    """
    config = get_config(mode)
    run_flow(
        mode=mode,
        server_url=server_url or config["server_url"],
        audience=audience or config["audience"],
        open_browser=open_browser,
    )


if __name__ == "__main__":
    cli()
