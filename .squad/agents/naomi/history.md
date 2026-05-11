# Naomi — Backend Developer History (Summarized)

**Owner:** Naomi (Backend Dev)  
**Project:** mcp-oauth — OAuth 2.0 / Entra integration on MCP server (Azure Web App)

---

## Key Learnings

### 1. UV Migration & App Structure (2026-05-09)

Migrated `server/` and `client/` to uv-based projects with proper entry points:
- `server/server.py` exposes module-level `app` for Starlette ASGI
- `server/startup.sh` runs `uv run uvicorn server:app`
- App Service `PORT` env var auto-configured by Azure
- Both projects keep `requirements.txt` (deprecated, pip fallback)

### 2. OAuth Root Cause Analysis (2026-05-08)

Cross-team findings confirmed two root causes for client hang:
- **H1 (HIGH):** Redirect URI mismatch (`http://localhost` vs `http://127.0.0.1`) — RFC 8252 §8.3 treats these as distinct
- **H2 (HIGH):** VS Code/Foundry don't use MCP server's `/token` endpoint — they expect Resource Server behavior (RFC 9728 PRM)

**Solution:** Switch from Authorization Server mode to Resource Server mode with direct Entra JWT validation.

### 3. RS-Mode Server Implementation (2026-05-08)

Built initial RS-mode server with:
- `EntraTokenValidator` — PyJWT + cryptography, RS256 validation, 1-hour JWKS cache
- `/.well-known/oauth-protected-resource` discovery endpoint
- Bearer token middleware + request-scoped context variable
- Mounted under `/mcp` in Starlette app (auth runs first, discovery stays public)

### 4. Post-Provision Verification (2026-05-09)

All infrastructure checks passed:
- Web app `cloud-helper-fastmcp` running in `rg-mcp-auth-test`
- Both prod (root) and staging slots with correct app registrations
- Redirect URIs: prod has bug preserved (`http://localhost` only), staging has fix (`127.0.0.1` + `localhost`)
- HTTP 200 health on both slots

### 5. Well-Known Routes — App Service Startup Fix (2026-05-09)

Root cause was deployment config drift, not route code:
- `appCommandLine` was empty → App Service fell back to gunicorn hosting page
- Missing `TENANT_ID` env var → app startup would fail if forced to run

**Fix applied:**
- Set startup: `python -m uvicorn server:app --host 0.0.0.0 --port 8000`
- Added `TENANT_ID` on both prod and staging
- Verified: both slots return 200 on `/.well-known/oauth-protected-resource` ✅

### 6. Test Client Refresh (2026-05-09)

Replaced legacy OAuth client with RS-mode PKCE flow:
- Fetches both `/.well-known` documents for discovery
- Loopback PKCE on `127.0.0.1` (demonstrates H1 redirect issue + fix)
- Direct Entra token exchange (no DCR)
- Calls MCP `/mcp` with bearer token

Subcommands: `repro` (prod slot, bug), `fixed` (staging slot, remedy)

### 7. Direct-Entra FastMCP Refactor (2026-05-11)

**Decision:** Refactor from custom `OAuthProxy` to FastMCP native RS-mode.

**What changed:**
- Removed `EntraOAuthProxy` class + proxy wiring (DCR, forwarded params)
- Implemented `RemoteAuthProvider` + `JWTVerifier` pattern
- FastMCP natively publishes RFC 9728 PRM at `/.well-known/oauth-protected-resource/mcp`
- Code reduction: ~235 → ~60 lines

**What stayed the same:**
- `auth.py` (EntraTokenValidator) — completely unchanged
- `config.py` — unchanged
- Tool definitions — unchanged

**Key insight:** `JWTVerifier` preserves Entra JWT claims on `AccessToken.claims`, so tools can extract `name`, `preferred_username`, `oid`, `tid` without manual decoding.

---

## Technical Decisions

**FastMCP native auth is the right path.** Significant code reduction, zero breaking changes, future-proof for token caching + introspection support in FastMCP upgrades. Risk is low because `auth.py` validation logic is untouched.

---

## Open Items

- VS Code AADSTS65002 issue awaits upstream VS Code MCP client fix or tenant admin Graph consent grant
- Python test client is the functional workaround for demo until VS Code implements resource-scoped token discovery

---

## Files & Artifacts

- `server/server.py` — FastMCP RS-mode with RemoteAuthProvider + JWTVerifier
- `server/auth.py` — EntraTokenValidator (unchanged from previous iterations)
- `server/config.py` — Settings management (unchanged)
- `client/test_client.py` — RS-mode PKCE test client with repro/fixed subcommands
- `.squad/agents/naomi/history-archive/{timestamp}-history.md` — Full detailed history (archived)

---

## Sprint Summary (2026-05-11)

✅ Direct-Entra FastMCP refactor complete  
✅ Well-known routes verified on both Azure slots  
✅ Test client RS-mode flow working  
✅ auth.py JWT validation unchanged  
✅ Code quality improved, maintainability increased  

**Next:** Live VS Code MCP flow validation with DevTools tracing to confirm resource-scoped token path and identity claims.

## Learnings

### 2026-05-11 — EasyAuth removal verification

- FastMCP 3.2.4 only exposed the path-scoped RFC 9728 endpoint at `/.well-known/oauth-protected-resource/mcp`; VS Code compatibility needs a root `/.well-known/oauth-protected-resource` alias that returns the same JSON without auth.
- `RemoteAuthProvider` + FastMCP's `RequireAuthMiddleware` already protect `POST /mcp` directly. Missing or invalid bearer tokens return `401` with a `WWW-Authenticate: Bearer ... resource_metadata=".../.well-known/oauth-protected-resource/mcp"` header that points clients at Entra-backed PRM metadata.
- App Service EasyAuth is not needed in `server.py`. The backend-side auth fix was to accept both Entra audience shapes for JWT validation: the app GUID (`aud`) and the `api://...` identifier URI clients request scopes against.

### 2026-05-11 — Cleanup pass after direct-Entra refactor

- The legacy `server/auth.py` module was fully dead code after the FastMCP native `JWTVerifier` migration, so removing it is the cleanest way to avoid drift and misleading future edits.
- `server/config.py` no longer needs `CLIENT_SECRET`; the active runtime inputs are tenant, client/resource identifiers, host, and optional `RESOURCE_APP_ID` for GUID-form `aud` validation.
- For the QA client, explicitly discovering PRM first and then reconnecting with `BearerAuth` makes failures much easier to localize: metadata discovery vs Entra sign-in/token issuance vs authenticated MCP calls.
- `uv export --no-hashes --no-dev --no-editable -o requirements.txt` currently emits a leading `.` entry for the packaged server project; that line is expected in the pip fallback file and is not an accidental dependency bump.

### 2026-05-11 — Cleanup Sprint: Server Cleanup + Auth Verification (D5, D6)

**Date:** 2026-05-11T15:10:26.063-04:00  
**Decisions:** D5 + D6 (merged into decisions.md)  
**Commit:** `4f680e2`

**What happened:** Removed dead authentication code and verified FastMCP native auth works without EasyAuth. Simplified test client for slot targeting.

**D5 — Server Cleanup:**
- **Deleted** `server/auth.py` — no longer in request path for FastMCP native auth
- **Simplified** `server/server.py` — kept only `RemoteAuthProvider` + `JWTVerifier` path
- **Simplified** `server/config.py` — removed `CLIENT_SECRET` (not used in direct-Entra RS-mode)
- **Regenerated** `server/requirements.txt` from `uv export`
- **Key decision:** Delete dead code instead of preserving for reference (keeps codebase clean)

**D6 — No EasyAuth Verification:**
- **Confirmed:** FastMCP 3.2.4 natively supports OAuth without EasyAuth middleware
- **Added:** Public RFC 9728 root alias at `/.well-known/oauth-protected-resource`
- **Broadened:** `JWTVerifier(audience=...)` to accept both:
  - App registration GUID (form in issued tokens)
  - `api://...` identifier URI (form in advertised scopes)
- **Verified locally:** GET well-known routes return 200; POST /mcp without auth returns 401; invalid tokens rejected correctly

**Test Client Enhancement:**
- Added `--url` flag (alias: `--server-url`) for flexible slot targeting
- Default: staging (fixed) slot
- Explicit RFC 9728 PRM discovery before auth

**Result:** Single active auth path (FastMCP native). Test client can target either production or staging. No dead code in request path.

**Impact:** Pairs with Holden's documentation trim (removed old docs explaining legacy paths) and Amos's deployment success (validates simplified code works). Completes cleanup sprint server-cleanup domain.
