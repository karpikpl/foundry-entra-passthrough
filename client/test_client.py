from __future__ import annotations

import base64
import hashlib
import json
import os
import secrets
import socket
import threading
import urllib.parse
import webbrowser
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

import click
import httpx
from dotenv import load_dotenv

ENV_FILE = Path(__file__).with_name(".env")
load_dotenv(ENV_FILE)

TENANT_ID = os.environ.get("TENANT_ID", "c29d6c2b-f765-41b3-b2a2-971a14239dfd")

ENVIRONMENTS = {
    "repro": {
        "server_url": os.environ.get("REPRO_SERVER_URL", "https://cloud-helper-fastmcp.azurewebsites.net"),
        "client_id": os.environ.get("REPRO_CLIENT_ID", "52e5e7ea-ba6a-4d66-91a3-785d2edc4d43"),
        "audience": os.environ.get("REPRO_AUDIENCE", "api://cloud-helper-mcp-repro-mcp-auth-test"),
        "expect_success": False,
    },
    "fixed": {
        "server_url": os.environ.get("FIXED_SERVER_URL", "https://cloud-helper-fastmcp-staging.azurewebsites.net"),
        "client_id": os.environ.get("FIXED_CLIENT_ID", "7810abd8-ed7b-40f4-a447-04cc1658eab6"),
        "audience": os.environ.get("FIXED_AUDIENCE", "api://cloud-helper-mcp-fixed-mcp-auth-test"),
        "expect_success": True,
    },
}


@dataclass
class CallbackResult:
    code: str | None = None
    state: str | None = None
    error: str | None = None
    error_description: str | None = None


class OAuthCallbackServer(ThreadingHTTPServer):
    def __init__(self, server_address: tuple[str, int]):
        super().__init__(server_address, CallbackHandler)
        self.result: CallbackResult | None = None
        self.event = threading.Event()


class CallbackHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        server = self.server
        if not isinstance(server, OAuthCallbackServer):
            raise RuntimeError("Unexpected server type")

        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        server.result = CallbackResult(
            code=params.get("code", [None])[0],
            state=params.get("state", [None])[0],
            error=params.get("error", [None])[0],
            error_description=params.get("error_description", [None])[0],
        )
        server.event.set()

        if server.result.error:
            body = (
                "<h1>Authorization failed</h1>"
                f"<p>{server.result.error}</p>"
                f"<p>{server.result.error_description or ''}</p>"
            )
        else:
            body = "<h1>Authorization complete</h1><p>You can close this tab.</p>"

        encoded = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, format: str, *args: Any) -> None:
        return


def generate_code_verifier() -> str:
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(64)).rstrip(b"=").decode("ascii")
    if not 43 <= len(verifier) <= 128:
        raise ValueError("PKCE code_verifier length is invalid")
    return verifier


def generate_code_challenge(verifier: str) -> str:
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")


def find_open_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def fetch_json(client: httpx.Client, url: str, label: str) -> dict[str, Any]:
    click.echo(label)
    try:
        response = client.get(url)
        response.raise_for_status()
    except httpx.HTTPError as exc:
        raise click.ClickException(f"Request failed for {url}: {exc}") from exc

    payload = response.json()
    if not isinstance(payload, dict):
        raise click.ClickException(f"Expected JSON object from {url}")
    return payload


def build_authorization_url(
    authorization_endpoint: str,
    client_id: str,
    redirect_uri: str,
    scope: str,
    state: str,
    code_challenge: str,
) -> str:
    query = urllib.parse.urlencode(
        {
            "client_id": client_id,
            "redirect_uri": redirect_uri,
            "response_type": "code",
            "scope": scope,
            "state": state,
            "code_challenge": code_challenge,
            "code_challenge_method": "S256",
        }
    )
    return f"{authorization_endpoint}?{query}"


def exchange_code_for_token(
    client: httpx.Client,
    token_endpoint: str,
    client_id: str,
    code: str,
    redirect_uri: str,
    code_verifier: str,
) -> dict[str, Any]:
    try:
        response = client.post(
            token_endpoint,
            data={
                "grant_type": "authorization_code",
                "client_id": client_id,
                "code": code,
                "redirect_uri": redirect_uri,
                "code_verifier": code_verifier,
            },
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        response.raise_for_status()
    except httpx.HTTPError as exc:
        raise click.ClickException(f"Token exchange failed: {exc}") from exc

    payload = response.json()
    if not isinstance(payload, dict):
        raise click.ClickException("Token endpoint did not return a JSON object")
    return payload


def call_mcp_tools_list(client: httpx.Client, server_url: str, access_token: str) -> dict[str, Any]:
    try:
        response = client.post(
            f"{server_url.rstrip('/')}/mcp",
            json={"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}},
            headers={
                "Authorization": f"Bearer {access_token}",
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
            },
        )
        response.raise_for_status()
    except httpx.HTTPError as exc:
        raise click.ClickException(f"MCP tools/list failed: {exc}") from exc

    payload = response.json()
    if not isinstance(payload, dict):
        raise click.ClickException("MCP endpoint did not return a JSON object")
    return payload


def run_flow(
    mode: str,
    server_url: str,
    client_id: str,
    audience: str,
    scope: str | None,
    timeout: int,
    open_browser: bool,
) -> None:
    config = ENVIRONMENTS[mode]
    effective_scope = scope or f"{audience}/mcp.access openid profile offline_access"
    callback_port = find_open_port()
    redirect_uri = f"http://127.0.0.1:{callback_port}"
    code_verifier = generate_code_verifier()
    code_challenge = generate_code_challenge(code_verifier)
    state = secrets.token_urlsafe(24)

    with httpx.Client(timeout=30.0, follow_redirects=True) as client:
        protected_resource = fetch_json(
            client,
            f"{server_url.rstrip('/')}/.well-known/oauth-protected-resource",
            "🔍 Fetching protected resource metadata...",
        )
        authorization_server = fetch_json(
            client,
            f"{server_url.rstrip('/')}/.well-known/oauth-authorization-server",
            "🔍 Fetching authorization server metadata...",
        )

        authorization_endpoint = authorization_server.get("authorization_endpoint")
        token_endpoint = authorization_server.get("token_endpoint")
        if not authorization_endpoint or not token_endpoint:
            raise click.ClickException("Authorization server metadata is missing authorization/token endpoints")

        click.echo("🔑 Starting OAuth PKCE flow...")
        click.echo(f"📡 Listening on {redirect_uri}...")
        click.echo(f"🧭 Tenant ID: {TENANT_ID}")
        click.echo(f"🪪 Client ID: {client_id}")
        click.echo(f"🎯 Scope: {effective_scope}")
        click.echo(f"🛡️ Authorization servers: {protected_resource.get('authorization_servers', [])}")

        callback_server = OAuthCallbackServer(("127.0.0.1", callback_port))
        callback_thread = threading.Thread(target=callback_server.serve_forever, daemon=True)
        callback_thread.start()

        auth_url = build_authorization_url(
            authorization_endpoint=authorization_endpoint,
            client_id=client_id,
            redirect_uri=redirect_uri,
            scope=effective_scope,
            state=state,
            code_challenge=code_challenge,
        )
        click.echo(f"🌐 Opening browser to: {auth_url}")
        if open_browser:
            opened = webbrowser.open(auth_url)
            if not opened:
                click.echo("⚠️ Could not open a browser automatically. Visit the URL above manually.")
        else:
            click.echo("ℹ️ Browser launch disabled; visit the URL above manually.")

        callback_received = callback_server.event.wait(timeout)
        callback_server.shutdown()
        callback_server.server_close()
        callback_thread.join(timeout=5)

        if not callback_received or callback_server.result is None:
            if not config["expect_success"]:
                click.echo("❌ REPRO CONFIRMED: no callback received — Entra likely rejected the 127.0.0.1 redirect URI before redirecting")
                return
            raise click.ClickException("Timed out waiting for the OAuth callback")

        result = callback_server.result
        if result.error:
            message = f"{result.error} — {result.error_description or 'no description provided'}"
            if not config["expect_success"]:
                click.echo(f"❌ REPRO CONFIRMED: {message}")
                return
            raise click.ClickException(message)

        if result.state != state:
            raise click.ClickException("OAuth state mismatch")
        if not result.code:
            raise click.ClickException("OAuth callback did not include an authorization code")

        token_payload = exchange_code_for_token(
            client=client,
            token_endpoint=token_endpoint,
            client_id=client_id,
            code=result.code,
            redirect_uri=redirect_uri,
            code_verifier=code_verifier,
        )
        access_token = token_payload.get("access_token")
        if not access_token:
            raise click.ClickException(f"Token response did not include access_token: {json.dumps(token_payload, indent=2)}")

        mcp_payload = call_mcp_tools_list(client, server_url, access_token)
        click.echo(f"✅ FIX CONFIRMED: {json.dumps(mcp_payload, indent=2)}")


COMMON_OPTIONS = [
    click.option("--server-url", help="Override the default server URL for the selected environment."),
    click.option("--client-id", help="Override the default Entra app registration client ID."),
    click.option("--audience", help="Override the default audience prefix (for example api://your-app-id-uri)."),
    click.option("--scope", help="Override the OAuth scope string sent to Entra."),
    click.option("--timeout", default=180, show_default=True, type=int, help="Seconds to wait for the OAuth callback."),
    click.option("--open-browser/--no-open-browser", default=True, show_default=True, help="Open the authorization URL in a browser automatically."),
]


def apply_common_options(func):
    for option in reversed(COMMON_OPTIONS):
        func = option(func)
    return func


@click.group()
def cli() -> None:
    """Local MCP OAuth PKCE test client."""


@cli.command()
@apply_common_options
def repro(
    server_url: str | None,
    client_id: str | None,
    audience: str | None,
    scope: str | None,
    timeout: int,
    open_browser: bool,
) -> None:
    config = ENVIRONMENTS["repro"]
    run_flow(
        mode="repro",
        server_url=server_url or config["server_url"],
        client_id=client_id or config["client_id"],
        audience=audience or config["audience"],
        scope=scope,
        timeout=timeout,
        open_browser=open_browser,
    )


@cli.command()
@apply_common_options
def fixed(
    server_url: str | None,
    client_id: str | None,
    audience: str | None,
    scope: str | None,
    timeout: int,
    open_browser: bool,
) -> None:
    config = ENVIRONMENTS["fixed"]
    run_flow(
        mode="fixed",
        server_url=server_url or config["server_url"],
        client_id=client_id or config["client_id"],
        audience=audience or config["audience"],
        scope=scope,
        timeout=timeout,
        open_browser=open_browser,
    )


if __name__ == "__main__":
    cli()
