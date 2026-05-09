# MCP OAuth PKCE Test Client

A minimal Python test client that exercises the **full OAuth 2.0 `authorization_code` + PKCE flow** against an MCP server. Built to reproduce and instrument the failure where the client receives the authorization code but never calls `/token`.

---

## Prerequisites

- Python 3.11+
- A running MCP server that implements `/.well-known/oauth-authorization-server`, `/register`, `/authorize`, and `/token`

---

## Install & Run

```bash
cd client
uv sync
uv run python test_oauth_client.py --server-url https://<your-mcp-server>
```

**Example against the Intel MCP server:**
```bash
uv run python test_oauth_client.py --server-url https://cloud-helper-mcp.azurewebsites.net
```

**Options:**
```
--server-url  (required) Base URL of the MCP server
--timeout     Seconds to wait for the browser callback (default: 120)
```

---

## What It Tests

The client exercises the exact sequence that AI Foundry and VS Code clients are expected to run:

| Phase | Step | Endpoint |
|-------|------|----------|
| 1 | Fetch server metadata | `GET /.well-known/oauth-authorization-server` |
| 1b | Dynamic client registration | `POST /register` |
| 2 | PKCE setup + open browser | `GET /authorize` (via browser) |
| 2 | Catch redirect | Local `http://127.0.0.1:<port>/` |
| **3** | **Token exchange** | **`POST /token`** ← the failing step |

---

## What to Look For in the Output

Every HTTP request and response is logged with a timestamp. Key markers:

```
★★★ CALLBACK RECEIVED ★★★          ← auth code arrived
  Auth code received: abc123…

=== PHASE 3: Token Exchange (/token POST) ===
★ Calling /token — this is the step that AI Foundry / VS Code skip ★

← HTTP 200 (142 ms)
  RESPONSE BODY (JSON): {
    "access_token": "eyJ…",
    ...
  }

✅ Full PKCE flow completed successfully — access_token obtained.
```

If the flow is broken you'll see one of:
- `❌ TIMEOUT — no callback received` — redirect never arrived
- `❌ STATE MISMATCH` — callback parsing or CSRF issue
- `❌ /token failed — HTTP 4xx/5xx` — server rejected the exchange
- `❌ Token exchange did not return an access_token` — partial response

---

## Capturing a Network Trace Alongside

Run `mitmproxy` in a separate terminal to capture everything on the wire:

```bash
# Terminal 1 — start mitmproxy
mitmproxy --listen-port 8080

# Terminal 2 — run the client through the proxy
HTTPS_PROXY=http://127.0.0.1:8080 \
  REQUESTS_CA_BUNDLE=$(python -c "import certifi; print(certifi.where())") \
  python test_oauth_client.py --server-url https://cloud-helper-mcp.azurewebsites.net
```

Or use Wireshark / `tcpdump` if you need raw packet captures:

```bash
sudo tcpdump -i any -w oauth-trace.pcap port 443 or port 80
```

> **Note:** The local callback server runs on `127.0.0.1` so it won't appear in `tcpdump` on `any` by default. Add `or port <callback-port>` if you need to capture it.

---

## How the PKCE Parameters Are Generated

| Parameter | Method |
|-----------|--------|
| `code_verifier` | 64 random bytes → URL-safe Base64, no padding (43–128 chars) |
| `code_challenge` | `BASE64URL(SHA256(ASCII(code_verifier)))` (S256 method) |
| `state` | `secrets.token_urlsafe(16)` — verified on callback |

---

## Interpreting the Bug

When AI Foundry or VS Code hang after login:
1. The browser **does** receive `http://127.0.0.1:<port>/?code=…` (step shows "Sign-in successful!")
2. The client **never** calls `POST /token`

This client will show whether:
- The callback is received correctly (look for `★★★ CALLBACK RECEIVED ★★★`)
- The state matches (look for `✅ State verified`)
- The `/token` POST fires at all (look for `=== PHASE 3`)
- The server accepts the exchange (look for `← HTTP 200`)

Share the full stdout log with the server-side team (Holden/Naomi) so they can correlate with server logs.
