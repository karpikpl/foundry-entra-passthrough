# Project Context

- **Owner:** Piotr Karpala
- **Project:** mcp-oauth — debugging and fixing an OAuth 2.0 authorization_code + PKCE flow on an MCP server (Azure Web App). After Entra login, the client never POSTs to /token — the token exchange hangs.
- **Stack:** MCP server (Azure Web App `cloud-helper-mcp`), Microsoft Entra ID, Azure AI Foundry (`foundry-kvmorale`), VS Code MCP client, OAuth 2.0 PKCE
- **Created:** 2026-05-08

## Learnings

<!-- Append new learnings below. Each entry is something lasting about the project. -->

- **2026-05-11:** Created comprehensive architecture documentation in `docs/architecture.md` covering the entire investigation, fix strategy, and implementation details. Key insights: (1) The original AS-mode design conflicted with how production clients (VS Code, Foundry) acquire tokens. (2) The fix requires three app registrations: proxy client, fixed resource server, and repro for comparison. (3) Claims pass-through via `upstream_claims` is the correct pattern for multi-hop auth. (4) Entra's `aud` field uses GUID format in v2.0 tokens, not the `api://` URI. (5) Scope split occurs when mixing OIDC scopes with custom resource scopes — omit OIDC scopes entirely. (6) Never manually decode JWTs in tools; rely on framework validation middleware.

- **2026-05-08:** The OAuth failure pattern is: Entra login completes successfully (user sees "Sign-in successful!") but the MCP client never POSTs to the server's `/token` endpoint. The connection hangs. This points to a client-side issue, not a server-side one. The server's `/token` endpoint works when tested manually.
- **2026-05-08:** Top two hypotheses: (1) Redirect URI mismatch — `http://127.0.0.1:<port>` vs `http://localhost` are NOT equivalent per RFC 8252 §8.3, and Entra may redirect to one while the client listens on the other. (2) The MCP client SDK may not implement the token exchange step at all, expecting the host app (VS Code / AI Foundry) to handle it. Both are HIGH confidence.
- **2026-05-08:** The Entra app registration platform type matters: "Mobile/Desktop" allows dynamic ports on localhost; "Web" requires exact URI match. This needs to be verified by Amos.
- **2026-05-08:** Key diagnostic: capture the browser Network tab during step 7. If the redirect to `http://127.0.0.1:<port>/` never fires (or fires but doesn't reach the client's listener), the problem is upstream of the token exchange entirely.

### 2026-05-08T17:50:48Z — CROSS-AGENT CONFIRMATION: H1 Validated by 3 Independent Sources

**H1 (HIGH) is now CONFIRMED:**
1. **Holden (Analysis):** RFC 8252 §8.3 theoretical foundation — `127.0.0.1` ≠ `localhost` for loopback OAuth redirects
2. **Naomi (Code Audit):** Confirmed in `client/test_oauth_client.py` — explicitly binds to `127.0.0.1`, sends `http://127.0.0.1:<port>/` in redirect_uri
3. **Amos (Entra Config):** Confirmed in app registration — `http://localhost` is registered, `http://127.0.0.1` is **NOT**

**This is the PRIMARY root cause of the OAuth flow hang.** Fix is ready: `az ad app update --id <APP_ID> --public-client-redirect-uris "http://localhost" "http://127.0.0.1"` (awaiting execution in "Cloud Brokers - ASC Testing" tenant by Valeria Morales).

### 2026-05-08T18:02:45Z — FINAL ROOT CAUSE CONFIRMED + FIX STRATEGY PRODUCED

**Root cause confirmed (all agents complete):**

- **Primary (H2 — Architectural):** `cloud-helper-mcp` operates as an MCP Authorization Server proxy (exposes `/authorize` + `/token`). VS Code and AI Foundry are RS-mode clients — they acquire tokens directly from Entra via `https://vscode.dev/redirect` / `https://foundry.azure.com/` and inject Bearer tokens. They never call the MCP server's `/token`. The "Sign-in successful" + hang symptom is explained entirely by this architectural mismatch: Entra login succeeds, the redirect lands somewhere the production clients own (not the MCP server), and the MCP server receives zero traffic.
- **Secondary (H1 — Config):** Test client sends `redirect_uri=http://127.0.0.1:<port>/` but only `http://localhost` is registered in Entra. Blocks standalone testing; not the reason VS Code/Foundry fail.

**Fix strategy produced:** Two phases.
- **Phase 1 (~30 min):** Amos runs `scripts/fix-entra-redirect-uri.sh` to add `http://127.0.0.1` to Entra registration. Unblocks test client. Requires tenant access (Piotr or Valeria).
- **Phase 2 (~1-2 days):** Naomi switches server from AS-mode to RS-mode: add `/.well-known/oauth-protected-resource` (RFC 9728), remove proxy `/authorize`+`/token`, add Bearer token validation middleware against Entra JWKS. Reference: onsemi `labs/mcp-prm-oauth` and `src/mcp-server/auth.py`.

**Blocking open question:** `cloud-helper-mcp` source code is not in this repo. Phase 2 cannot begin until Naomi has access to the server source.

**Output:** `.squad/decisions/inbox/holden-final-root-cause-fix-strategy.md`

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

### 2026-05-08T22:48:54Z — BUILD DECISION: FastMCP RS-mode from Scratch

**Piotr confirmed:** Original `cloud-helper-mcp` source is not available. Team will build new.

**Build decision approved:**
- **Framework:** FastMCP (Python) — `mcp[cli]` package
- **Mode:** RS-mode (Resource Server), NOT AS-mode
- **Auth:** Bearer token validation against Entra JWKS; RFC 9728 discovery
- **Scope:** Hello World server — auth plumbing is the deliverable
- **Team assignments:** Naomi building `server/`, Amos building Entra RS-mode registration script

**Why:** VS Code and AI Foundry are RS-mode clients. They acquire tokens from Entra directly and inject Bearer tokens. Building AS-mode proxy (original attempt) causes the hang we debugged.

### 2026-05-09T03:04:39Z — Two-app-registration + slot strategy decision completed

**Decision:** `.squad/decisions/archive/holden-two-appreg-slot-strategy.md`

- Approved two Entra app registrations for the same FastMCP RS-mode server: **repro** keeps `http://localhost` only; **fixed** adds `http://127.0.0.1`.
- Recommended using slot URLs as two live auth profiles rather than relying on slot swap as the main broken/fixed switch.
- Preferred mapping: staging slot = repro, production slot = fixed.
- Marked `CLIENT_ID`, `AUDIENCE`, and `RESOURCE_HOST` as sticky slot settings.

### 2026-05-10T01:11:03Z — FastMCP Native Entra/OIDC Research

**Decision:** `.squad/decisions/inbox/holden-fastmcp-entra-native-auth.md`

- **`TokenVerifier` is the official integration point.** FastMCP (`mcp/server/auth/provider.py`) defines `TokenVerifier` as a `Protocol` with one method: `async def verify_token(token: str) -> AccessToken | None`. Pass a custom implementation to `FastMCP(token_verifier=...)`. This is the designed hook for external OIDC providers like Entra.
- **`resource_server_url` + `issuer_url` natively serve the PRM.** When both are set, FastMCP auto-registers `GET /.well-known/oauth-protected-resource/mcp` with `resource` = `resource_server_url` and `authorization_servers` = `[issuer_url]` (Entra). Our custom `well_known.py` PRM route is now redundant.
- **RS-mode = `token_verifier` only, no `auth_server_provider`.** FastMCP registers no `/authorize`, `/token`, or AS metadata routes. Just PRM + bearer extraction + scope enforcement.
- **FastMCP does NOT validate JWTs.** All JWKS fetching, RS256 validation, `kid` rotation, `scp`/`roles` parsing stays in `auth.py` — zero changes there. The `EntraTokenVerifier` adapter is ~15 lines.
- **`get_access_token()` from `auth_context`.** FastMCP stores the resolved `AccessToken` in a contextvar via `AuthContextMiddleware`. Tools call `get_access_token()` instead of our custom `get_token_claims()`. AccessToken has `client_id`, `scopes`, `token`, `expires_at` — no raw claims. If `sub` is needed, extend `AccessToken` with a `subject` field.
- **`BearerTokenAuthMiddleware` and `build_well_known_routes()` are now replaceable.** Refactor collapses `server.py` from ~235 to ~60 lines. `well_known.py` can be deleted. `auth.py` and `config.py` untouched. Risk: low.
