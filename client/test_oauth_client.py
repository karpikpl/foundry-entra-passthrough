"""
Minimal OAuth 2.0 PKCE test client for MCP servers.

Exercises the full authorization_code + PKCE flow and explicitly logs
whether /token is ever called — designed to reproduce the hang where
the client receives the auth code but never exchanges it.

Usage:
    python test_oauth_client.py --server-url https://<your-mcp-server>
"""

import argparse
import base64
import hashlib
import http.server
import json
import logging
import os
import secrets
import socket
import sys
import threading
import time
import urllib.parse
import webbrowser
from datetime import datetime, timezone

import requests

# ---------------------------------------------------------------------------
# Logging setup — every HTTP exchange gets a timestamp prefix
# ---------------------------------------------------------------------------

LOG_FMT = "%(asctime)s.%(msecs)03d  %(levelname)-7s  %(message)s"
logging.basicConfig(
    level=logging.DEBUG,
    format=LOG_FMT,
    datefmt="%H:%M:%S",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("oauth-client")

# Make requests itself quiet; we log manually below.
logging.getLogger("urllib3").setLevel(logging.WARNING)
logging.getLogger("urllib3.connectionpool").setLevel(logging.WARNING)


def ts() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


# ---------------------------------------------------------------------------
# HTTP instrumentation — wraps requests so we see every byte
# ---------------------------------------------------------------------------

class LoggedSession(requests.Session):
    """requests.Session that prints full request/response pairs."""

    def request(self, method: str, url: str, **kwargs):
        log.info("──────────────────────────────────────────────")
        log.info(f"→ {method.upper()} {url}")

        # Log request body if present
        body = kwargs.get("data") or kwargs.get("json")
        if body:
            log.info(f"  REQUEST BODY: {body}")
        req_headers = kwargs.get("headers", {})
        if req_headers:
            log.info(f"  REQUEST HEADERS: {req_headers}")

        t0 = time.monotonic()
        resp = super().request(method, url, **kwargs)
        elapsed_ms = (time.monotonic() - t0) * 1000

        log.info(f"← HTTP {resp.status_code} ({elapsed_ms:.0f} ms)")
        log.info(f"  RESPONSE HEADERS: {dict(resp.headers)}")
        try:
            body_text = resp.json()
            log.info(f"  RESPONSE BODY (JSON): {json.dumps(body_text, indent=2)}")
        except Exception:
            log.info(f"  RESPONSE BODY (text): {resp.text[:2000]}")
        log.info("──────────────────────────────────────────────")
        return resp


http = LoggedSession()


# ---------------------------------------------------------------------------
# PKCE helpers
# ---------------------------------------------------------------------------

def generate_code_verifier() -> str:
    """RFC 7636 §4.1 — 43-128 URL-safe base64 chars, no padding."""
    raw = secrets.token_bytes(64)
    verifier = base64.urlsafe_b64encode(raw).rstrip(b"=").decode()
    assert 43 <= len(verifier) <= 128
    return verifier


def derive_code_challenge(verifier: str) -> str:
    """RFC 7636 §4.2 — S256: BASE64URL(SHA256(ASCII(verifier)))."""
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b"=").decode()


# ---------------------------------------------------------------------------
# Local callback server — catches the redirect from Entra/MCP
# ---------------------------------------------------------------------------

class CallbackHandler(http.server.BaseHTTPRequestHandler):
    """Single-shot HTTP handler that captures the OAuth callback."""

    result: dict | None = None  # populated on first GET /?code=...

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)

        log.info("★★★ CALLBACK RECEIVED ★★★")
        log.info(f"  Path: {self.path}")
        log.info(f"  Params: {params}")

        code = params.get("code", [None])[0]
        state = params.get("state", [None])[0]
        error = params.get("error", [None])[0]

        if error:
            log.error(f"  Authorization error: {error} — {params.get('error_description', [''])}")
            body = f"<h1>Error: {error}</h1><p>{params.get('error_description', [''])}</p>".encode()
        elif code:
            log.info(f"  Auth code received: {code[:12]}…  state={state}")
            body = b"<h1>Authorization code received.</h1><p>You can close this tab.</p>"
        else:
            log.warning("  Callback had neither code nor error — unexpected.")
            body = b"<h1>Unexpected callback</h1>"

        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

        # Store result so the main thread can pick it up
        CallbackHandler.result = {"code": code, "state": state, "error": error}

    def log_message(self, fmt, *args):
        # Suppress default server logging; we handle it ourselves
        pass


def find_free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def start_callback_server(port: int) -> http.server.HTTPServer:
    server = http.server.HTTPServer(("127.0.0.1", port), CallbackHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    log.info(f"Callback server listening on http://127.0.0.1:{port}/")
    return server


# ---------------------------------------------------------------------------
# Phase 1 — Discovery
# ---------------------------------------------------------------------------

def discover(server_url: str) -> dict:
    log.info("=== PHASE 1: Discovery ===")
    url = f"{server_url.rstrip('/')}/.well-known/oauth-authorization-server"
    resp = http.get(url, timeout=15)
    resp.raise_for_status()
    meta = resp.json()
    log.info(f"Discovered metadata from {url}")
    return meta


# ---------------------------------------------------------------------------
# Phase 1b — Dynamic client registration
# ---------------------------------------------------------------------------

def register_client(registration_endpoint: str, redirect_uri: str) -> dict:
    log.info("=== PHASE 1b: Dynamic Client Registration ===")
    payload = {
        "redirect_uris": [redirect_uri],
        "token_endpoint_auth_method": "none",  # public client
        "grant_types": ["authorization_code"],
        "response_types": ["code"],
        "client_name": "MCP OAuth Test Client",
    }
    resp = http.post(registration_endpoint, json=payload, timeout=15)
    resp.raise_for_status()
    reg = resp.json()
    log.info(f"Registered — client_id: {reg.get('client_id')}")
    return reg


# ---------------------------------------------------------------------------
# Phase 2 — PKCE Authorization
# ---------------------------------------------------------------------------

def build_authorize_url(
    authorization_endpoint: str,
    client_id: str,
    redirect_uri: str,
    scope: str,
    state: str,
    code_challenge: str,
) -> str:
    params = {
        "response_type": "code",
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "scope": scope,
        "state": state,
        "code_challenge": code_challenge,
        "code_challenge_method": "S256",
    }
    return f"{authorization_endpoint}?{urllib.parse.urlencode(params)}"


# ---------------------------------------------------------------------------
# Phase 3 — Token Exchange
# ---------------------------------------------------------------------------

def exchange_token(
    token_endpoint: str,
    code: str,
    redirect_uri: str,
    client_id: str,
    code_verifier: str,
) -> dict:
    log.info("=== PHASE 3: Token Exchange (/token POST) ===")
    log.info("★ Calling /token — this is the step that AI Foundry / VS Code skip ★")

    payload = {
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": redirect_uri,
        "client_id": client_id,
        "code_verifier": code_verifier,
    }
    log.info(f"POST {token_endpoint}")
    log.info(f"  grant_type=authorization_code")
    log.info(f"  code={code[:12]}…")
    log.info(f"  redirect_uri={redirect_uri}")
    log.info(f"  client_id={client_id}")
    log.info(f"  code_verifier={code_verifier[:12]}…")

    resp = http.post(
        token_endpoint,
        data=payload,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        timeout=30,
    )

    if resp.status_code == 200:
        log.info("✅ /token succeeded — token exchange complete!")
    else:
        log.error(f"❌ /token failed — HTTP {resp.status_code}")

    return resp.json() if resp.ok else {"error": resp.text}


# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

def run(server_url: str, timeout_secs: int):
    log.info(f"Starting OAuth PKCE test against: {server_url}")
    log.info(f"Timestamp: {ts()}")

    # --- Phase 1: Discovery ---
    metadata = discover(server_url)
    auth_endpoint = metadata.get("authorization_endpoint")
    token_endpoint = metadata.get("token_endpoint")
    reg_endpoint = metadata.get("registration_endpoint")

    if not auth_endpoint:
        log.error("No authorization_endpoint in metadata — aborting.")
        sys.exit(1)
    if not token_endpoint:
        log.error("No token_endpoint in metadata — aborting.")
        sys.exit(1)

    log.info(f"authorization_endpoint: {auth_endpoint}")
    log.info(f"token_endpoint:         {token_endpoint}")
    log.info(f"registration_endpoint:  {reg_endpoint}")

    # --- Phase 1b: Registration ---
    port = find_free_port()
    redirect_uri = f"http://127.0.0.1:{port}/"

    if reg_endpoint:
        reg = register_client(reg_endpoint, redirect_uri)
        client_id = reg.get("client_id", "test-client")
    else:
        log.warning("No registration_endpoint — using placeholder client_id.")
        client_id = "test-client"

    log.info(f"Using client_id: {client_id}")

    # --- Phase 2: PKCE setup ---
    log.info("=== PHASE 2: PKCE Authorization ===")
    code_verifier = generate_code_verifier()
    code_challenge = derive_code_challenge(code_verifier)
    state = secrets.token_urlsafe(16)
    scope = "openid profile offline_access"

    log.info(f"code_verifier (first 12): {code_verifier[:12]}…  len={len(code_verifier)}")
    log.info(f"code_challenge:           {code_challenge}")
    log.info(f"state:                    {state}")

    # Start callback server before opening browser
    server = start_callback_server(port)
    CallbackHandler.result = None  # reset

    auth_url = build_authorize_url(
        auth_endpoint, client_id, redirect_uri, scope, state, code_challenge
    )
    log.info(f"Opening browser → {auth_url}")
    webbrowser.open(auth_url)

    # --- Wait for callback ---
    log.info(f"Waiting up to {timeout_secs}s for callback on {redirect_uri} …")
    deadline = time.monotonic() + timeout_secs
    while CallbackHandler.result is None and time.monotonic() < deadline:
        time.sleep(0.25)

    server.shutdown()

    if CallbackHandler.result is None:
        log.error("❌ TIMEOUT — no callback received. The browser may not have redirected.")
        log.error("   This suggests the auth flow failed before the redirect, or the")
        log.error("   redirect_uri is not reachable from the browser.")
        sys.exit(1)

    result = CallbackHandler.result
    if result.get("error"):
        log.error(f"❌ Authorization error: {result['error']}")
        sys.exit(1)

    code = result["code"]
    returned_state = result["state"]

    # --- State verification ---
    if returned_state != state:
        log.error(f"❌ STATE MISMATCH — sent={state!r}  got={returned_state!r}")
        log.error("   Possible CSRF or callback parsing issue.")
        sys.exit(1)
    log.info("✅ State verified.")

    if not code:
        log.error("❌ No auth code in callback — cannot proceed to /token.")
        log.error("   This is Phase 3 failure point: AI Foundry / VS Code stop here.")
        sys.exit(1)

    # --- Phase 3: Token Exchange ---
    token_data = exchange_token(
        token_endpoint, code, redirect_uri, client_id, code_verifier
    )

    log.info("=== FINAL RESULT ===")
    log.info(json.dumps(token_data, indent=2))

    if "access_token" in token_data:
        log.info("✅ Full PKCE flow completed successfully — access_token obtained.")
        log.info(f"  token_type:  {token_data.get('token_type')}")
        log.info(f"  expires_in:  {token_data.get('expires_in')}")
        log.info(f"  scope:       {token_data.get('scope')}")
        has_refresh = "refresh_token" in token_data
        log.info(f"  refresh_token present: {has_refresh}")
    else:
        log.error("❌ Token exchange did not return an access_token.")
        log.error(f"  Error: {token_data.get('error')} — {token_data.get('error_description')}")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Minimal OAuth 2.0 PKCE test client for MCP servers."
    )
    parser.add_argument(
        "--server-url",
        required=True,
        help="Base URL of the MCP server, e.g. https://cloud-helper-mcp.azurewebsites.net",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=120,
        help="Seconds to wait for the browser callback (default: 120)",
    )
    args = parser.parse_args()

    # Normalise — strip trailing slash
    server_url = args.server_url.rstrip("/")

    run(server_url, args.timeout)


if __name__ == "__main__":
    main()
