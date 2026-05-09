# Project Context

- **Owner:** Piotr Karpala
- **Project:** mcp-oauth — debugging and fixing an OAuth 2.0 authorization_code + PKCE flow on an MCP server (Azure Web App). After Entra login, the client never POSTs to /token — the token exchange hangs.
- **Stack:** MCP server (Azure Web App `cloud-helper-mcp`), Microsoft Entra ID, Azure AI Foundry (`foundry-kvmorale`), VS Code MCP client, OAuth 2.0 PKCE
- **Created:** 2026-05-08

## Learnings

### 2026-05-09T04:22:42Z — UV migration: server/ and client/

- **Entry point:** `server.py` exposes a module-level `app = create_app()` and the `if __name__ == "__main__":` block. Refactored into a proper `main()` function so `[project.scripts]` can reference `server:main`. The uvicorn startup in `main()` reads `settings.port` (env-driven via `PORT`, default 8000).
- **server/ UV project:** `pyproject.toml` with `name = "cloud-helper-fastmcp"`, requires Python ≥ 3.12, resolved to 44 packages in `uv.lock`. Dropped `fastapi` (not imported directly — Starlette is pulled via `mcp[cli]`) and `python-dotenv` (covered by `pydantic-settings`). Upgraded `cryptography` floor to ≥42.0, `uvicorn[standard]` floor to ≥0.29.
- **client/ UV project:** `pyproject.toml` with `name = "mcp-oauth-test-client"`. Only external dep is `requests` — all other imports in `test_oauth_client.py` are stdlib. Resolved to 6 packages.
- **Startup script:** `server/startup.sh` uses `uv run uvicorn server:app` and reads `${PORT:-8080}` — App Service injects `PORT` automatically. Set startup command to `bash startup.sh`.
- **Makefile:** `Makefile` at repo root with `install`, `dev`, `run-uvx`, `client-install`, `client-run` targets.
- **App Service deploy note:** `uvx --from ./server cloud-helper-fastmcp` works for zero-install runs if uv is on the App Service PATH (requires custom startup or base image with uv). `bash startup.sh` is the safer option for App Service.
- **`requirements.txt` retention:** Both `server/` and `client/` keep their `requirements.txt` with a `DEPRECATED` notice at the top. Useful as a pip emergency fallback without uv.

### 2026-05-08T22:48:54Z — Built replacement FastMCP RS-mode OAuth server

- Built a fresh `server/` implementation that uses **RS-mode OAuth**: root `/.well-known/oauth-protected-resource` points clients at Entra, and the MCP endpoint only accepts Bearer tokens instead of exposing `/authorize` or `/token`.
- Implemented `EntraTokenValidator` with **PyJWT + cryptography**, a **1-hour JWKS cache**, and explicit validation for signature, issuer, audience, and expiry.
- Mounted FastMCP under `/mcp` inside a Starlette app so authentication middleware runs first and `/.well-known/` discovery stays public at the root.
- Passed validated claims through a request-scoped context variable so the hello tool can confirm authenticated execution and log the caller subject.


### 2026-05-08T17:46:22Z — Cross-Agent Finding: Root cause analysis (from Holden)

**H1 (HIGH): Redirect URI mismatch** — The Entra app registration lists `http://localhost` (any port). But Entra's redirect lands on `http://127.0.0.1:<port>/`. Per RFC 8252 §8.3, loopback redirects MUST use `http://127.0.0.1` or `http://[::1]` — NOT `http://localhost`. Entra's platform may not treat these as equivalent. If client listener is on `127.0.0.1` but Entra redirects to `localhost` (or vice versa), callback never arrives.

**H2 (HIGH): SDK may not implement token exchange** — MCP specification defines server-side OAuth support, but client-side token exchange may not be in MCP client SDK. If the SDK relies on host application (VS Code / AI Foundry) to complete exchange, and host doesn't know the MCP server's `/token` endpoint, no POST ever happens.

**Action items for Naomi:**
1. Inspect `/.well-known/oauth-authorization-server` response — what `redirect_uris` are advertised?
2. Check `/authorize` endpoint — what `redirect_uri` does client send? Does server validate?
3. Check CORS headers on `/token`
4. Add request logging to `/token` endpoint
5. Check if server has a `/callback` endpoint that proxies the OAuth flow

**See:** `.squad/decisions/inbox/holden-oauth-root-cause-analysis.md` for full hypothesis list and investigation work plan

### 2026-05-08T17:46:22Z — Server code audit: OAuth token endpoint investigation

- **No server source code in this repo.** The `cloud-helper-mcp` Azure Web App code is not committed here. All server-side conclusions are based on the customer's self-reported endpoint behavior and what can be inferred from the issue description. The server code must be obtained from the customer or the deployment to audit CORS, PKCE validation, and Entra proxy call logic.
- **IP restriction on all endpoints.** The Azure Web App returns `403 Ip Forbidden` (with `x-ms-forbidden-ip`) for all requests from this machine. All direct curl probes failed. This means live endpoint probing requires either an Azure-internal IP or the IP allowlist being updated. Amos must investigate `az webapp show siteConfig.ipSecurityRestrictions`.
- **H1 (redirect URI mismatch) is confirmed in the test client code.** `client/test_oauth_client.py` explicitly binds to `127.0.0.1` and constructs `redirect_uri = http://127.0.0.1:{port}/`. The Entra registration only lists `http://localhost` — not `http://127.0.0.1`. Per RFC 8252 §8.3 these are distinct. This is the most likely root cause for the test client failing.
- **Server architecture: pass-through proxy.** The issue description's language ("our `/token` endpoint is never called by the client") confirms the server owns a `/token` endpoint that the client initiates. The server then likely proxies to Entra's `/token`. This is the expected MCP OAuth model. H2 is false for the test client (which does implement Phase 3), but unconfirmed for AI Foundry and VS Code native clients.
- **CORS on `/token` is unverifiable from this machine** due to IP restriction. This remains an open question specifically for the AI Foundry browser-based client scenario (H6). Amos must check `az webapp cors show` for `cloud-helper-mcp`.
- **Fix priority:** (1) Add `http://127.0.0.1` to Entra app registration redirect URIs — platform type must be Mobile/Desktop for dynamic port support. (2) Update server metadata to advertise both `http://localhost` and `http://127.0.0.1`. (3) Confirm CORS headers on `/token` for `https://foundry.azure.com`.

### 2026-05-08T17:50:48Z — CROSS-AGENT CONFIRMATION: H1 + IP Allowlisting Finding

**H1 (HIGH) is now CONFIRMED by 3 independent sources:**
1. **Holden (Analysis):** RFC 8252 §8.3 — `127.0.0.1` ≠ `localhost`
2. **Naomi (Code Audit):** Confirmed in test client — binds to `127.0.0.1`, sends in redirect_uri
3. **Amos (Entra Config):** Confirmed in app registration — `http://localhost` only, `http://127.0.0.1` missing

**IP Allowlisting secondary finding (from Naomi's audit):**
- Azure Web App blocks IP 70.231.17.250 with 403 Ip Forbidden
- Prevents live endpoint probing but not the cause of OAuth hang
- Should be addressed during remediation


### 2026-05-08T18:02:45Z — CROSS-PROPAGATION: H2 CONFIRMED + RS-MODE ARCHITECTURAL FIX REQUIRED

**Monica's research confirms H2 with architectural clarity:**

- **H2 CONFIRMED (HIGH):** VS Code and AI Foundry do NOT invoke the MCP server's /token endpoint. They use their own OAuth frameworks that obtain Bearer tokens directly from Entra ID (`https://vscode.dev/redirect` for VS Code, `https://foundry.azure.com/` for Foundry) and bypass the MCP server's Authorization Server role entirely.
- **Architectural root cause:** The intel `cloud-helper-mcp` acts as an MCP Authorization Server, but production clients expect Resource Server behavior (RFC 9728 PRM).
- **Reference:** onsemi `labs/mcp-prm-oauth` demonstrates the correct pattern: MCP server publishes `/.well-known/oauth-protected-resource` pointing to Entra, validates Bearer tokens using JWT validation.
- **Key evidence:** MCP spec, VS Code source (`IAuthenticationService`, `https://vscode.dev/redirect`), Foundry OAuth passthrough docs, MCP Python SDK analysis.

**Recommended RS-mode switch:**
1. Remove `/authorize` and `/token` proxy endpoints
2. Add `/.well-known/oauth-protected-resource` (RFC 9728 PRM) → Entra
3. Validate Bearer tokens via JWT validation middleware
4. Clients automatically use this metadata to route tokens through Entra

**Status:** H1 + H2 both confirmed. Fix strategy ready for Phase 2 implementation.
