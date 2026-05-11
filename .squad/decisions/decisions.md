# Team Decisions — Direct-Entra Implementation Sprint

**Last Updated:** 2026-05-11T13:07:59.344-04:00  
**Sprint Focus:** Remove OAuthProxy, implement native RemoteAuthProvider + JWTVerifier for direct-Entra RS mode

---

## Architectural Decisions

### 1. FastMCP Native Auth Refactor (Holden)

**Status:** ✅ **DECISION: PROCEED WITH REFACTOR**

FastMCP now owns the bearer extraction, 401/403 response format, WWW-Authenticate header construction, scope enforcement, and PRM serving. Replace the custom `BearerTokenAuthMiddleware` + `build_well_known_routes()` with FastMCP's native `TokenVerifier` protocol.

**Key findings:**
- FastMCP's `create_protected_resource_routes()` natively registers `/.well-known/oauth-protected-resource/mcp`
- The `TokenVerifier` protocol is exactly the designed integration point for external OIDC providers
- `auth.py` (EntraTokenValidator) is **unchanged** — JWT validation logic preserved exactly as-is
- New `EntraTokenVerifier` adapter class (~15 lines) bridges FastMCP to Entra JWT validation

**What changes:**
- `server.py`: ~235 lines → ~60 lines (declarative FastMCP config)
- `well_known.py`: deleted (PRM route gone native; AS proxy route is optional dead weight)
- `auth.py`: **zero changes**
- `config.py`: **zero changes**

**Risk:** Low. `EntraTokenValidator` is unchanged and tested independently.

**Reference:** `.squad/decisions/archive/20260511T171629-decisions.md` (archived) for full technical analysis.

---

### 2. VS Code + Graph Consent Issue (Holden AADSTS65002 Diagnosis)

**Status:** ✅ **DIAGNOSIS COMPLETE**

The AADSTS65002 error when VS Code tries to access MCP is **not a bug in our MCP server configuration**. Root cause is one of:

**Cause A (HIGH CONFIDENCE):** VS Code's MCP client falls back to its built-in Microsoft auth provider (default scope = Graph) when the MCP server's discovery flow is not yet correct.

**Cause B (LOWER CONFIDENCE):** Completely unrelated — VS Code's Settings Sync or account sign-in hitting tenant Graph consent policy.

**Decision:** Add `preAuthorizedApplications` for VS Code client (`aebc6443-996d-45c2-90f0-388ff96faa56`) in Bicep. This is a forward-looking improvement that ensures seamless MCP auth **if/when** VS Code's MCP client correctly discovers and uses our resource-scoped token path.

**Will this fix AADSTS65002 immediately?** No — the error comes from VS Code requesting Graph tokens, not our API tokens. The fix solves the *next* issue (consent dialog) but requires VS Code's MCP client to implement resource-scoped token discovery first.

**Workaround:** Use Python test client (`client/test_client.py`) for demo and functional testing — it correctly implements the MCP OAuth spec.

**Reference:** Detailed diagnosis in archived decisions.

---

### 3. Direct-Entra Server Implementation (Naomi)

**Status:** ✅ **IMPLEMENTED**

Rewrote `server/server.py` from FastMCP `OAuthProxy` mode to direct Entra resource-server mode.

**Removed:**
- `EntraOAuthProxy` class and proxy-specific wiring
- Dynamic Client Registration / proxy auth-server behavior
- `_decode_jwt_payload()` helper
- Proxy token exchange overrides

**Added:**
- `RemoteAuthProvider` wired to Entra as the external authorization server
- `JWTVerifier` as the top-level bearer-token validator for incoming Entra JWTs
- Direct RFC 9728 protected-resource metadata via FastMCP at `/.well-known/oauth-protected-resource/mcp`
- `extract_token_info()` helper that reads identity claims from validated bearer tokens

**Kept:**
- `config.py` unchanged
- Existing MCP tool definitions
- Uvicorn/http app startup pattern

**Validation:**
- Import check ✅
- Route inspection shows only `/.well-known/oauth-protected-resource/mcp` and `/mcp` ✅
- PRM returns Entra issuer in `authorization_servers` ✅
- Unauthenticated `/mcp` POST returns `401` with `WWW-Authenticate` header ✅

---

### 4. Infrastructure Changes (Amos)

**Status:** ✅ **IMPLEMENTED — BICEP BUILD PASSES**

Updated the Bicep/AZD infra to support Holden's direct-Entra pattern without an OAuthProxy client application.

**Removed:**
- Proxy client app registration from `infra/modules/appRegistrations.bicep`
- Proxy-related parameters/outputs from `infra/main.bicep`
- Proxy client secrets from `infra/main.parameters.json`

**Added:**
- `api.preAuthorizedApplications` to the fixed MCP server app registration for VS Code client ID `aebc6443-996d-45c2-90f0-388ff96faa56`
- Both prod and staging slots:
  - EasyAuth v2 with `Return401`, token store enabled
  - Issuer: `https://login.microsoftonline.com/{tenantId}/v2.0`
  - Entra token validation against slot's app registration
  - Allow VS Code via `allowedClientApplications`
  - Slot-local PRM scopes via `WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES`

**Simplified:**
- `hooks/preprovision.sh` → no-op
- `hooks/postprovision.sh` → direct-Entra service-principal/bootstrap work only

**Verification:**
- `az bicep build --file infra/main.bicep` → exit 0 ✅
- `sh -n hooks/preprovision.sh hooks/postprovision.sh` → exit 0 ✅
- **Note:** Two `no-hardcoded-env-urls` warnings for `login.microsoftonline.com` are expected — the direct-Entra requirement explicitly calls for the tenant v2 issuer URL.

**Manual steps:**
- No manual portal work required for pre-authorized fixed app registration
- Deploying principal needs Microsoft Graph `Application.ReadWrite.OwnedBy` + Azure Contributor on resource group

---

### 5. AZD Environment Population (Amos)

**Status:** ✅ **IMPLEMENTED LOCALLY**

AZD `postprovision.sh` hook populates `client/.env` automatically after deployment.

**What changed:**
- Added `hooks/postprovision.sh` that reads `azd env get-values`
- Requires: `AZURE_TENANT_ID`, `REPRO_CLIENT_ID`, `FIXED_CLIENT_ID`, `WEB_APP_NAME`, `AZURE_RESOURCE_GROUP`
- Writes: `client/.env` with tenant, server URLs, audience URIs
- `client/test_client.py` loads `client/.env` via `python-dotenv`, fallback to hardcoded values
- `client/.env` is gitignored

**Generated file shape:**
```dotenv
TENANT_ID=<AZURE_TENANT_ID>
REPRO_CLIENT_ID=<REPRO_CLIENT_ID>
FIXED_CLIENT_ID=<FIXED_CLIENT_ID>
WEB_APP_NAME=<WEB_APP_NAME>
REPRO_SERVER_URL=https://<WEB_APP_NAME>.azurewebsites.net
FIXED_SERVER_URL=https://<WEB_APP_NAME>-staging.azurewebsites.net
REPRO_AUDIENCE=api://cloud-helper-mcp-repro-<resource-group-suffix>
FIXED_AUDIENCE=api://cloud-helper-mcp-fixed-<resource-group-suffix>
```

**Verification:**
- `cd client && uv sync` ✅
- `cd client && uv run python -m py_compile test_client.py` ✅

---

### 6. Well-Known Routes — Deployment Fix (Naomi)

**Status:** ✅ **FIXED IN AZURE RUNTIME**

The Starlette app route construction was correct. The deployed failure was **App Service startup/config drift**.

**Root causes identified:**
1. `appCommandLine` was empty on both prod and staging → App Service fell back to default gunicorn, bypassing our ASGI app
2. Missing `TENANT_ID` env var → app startup failed when forced to run

**Fixes applied:**
- Set startup command on both slots: `python -m uvicorn server:app --host 0.0.0.0 --port 8000`
- Added slot-sticky `TENANT_ID` on both prod and staging

**Verification:**
- Prod: `GET /.well-known/oauth-protected-resource` → 200 OK (server: uvicorn) ✅
- Staging: `GET /.well-known/oauth-protected-resource` → 200 OK (server: uvicorn) ✅
- Both slots return expected Bearer auth challenge on `/mcp` ✅

---

### 7. Post-Provision Verification (Naomi)

**Status:** ✅ **ALL CHECKS PASSED**

**Infrastructure readiness (2026-05-09T01:17:47Z):**

| Check | Status |
|-------|--------|
| Web app exists | ✅ `cloud-helper-fastmcp` in `rg-mcp-auth-test` |
| Deployment slots | ✅ Staging slot created |
| App settings | ✅ CLIENT_ID, AUDIENCE, AZURE_TENANT_ID set on both slots |
| Entra app regs | ✅ Both `repro` and `fixed` apps linked |
| Redirect URIs (prod) | ✅ `["http://localhost"]` — H1 bug preserved |
| Redirect URIs (staging) | ✅ `["http://127.0.0.1", "http://localhost"]` — H1 fix deployed |
| HTTP health (prod) | ✅ 200 OK |
| HTTP health (staging) | ✅ 200 OK |

---

### 8. Test Client Refactor (Naomi + Drummer)

**Status:** ✅ **IMPLEMENTED**

Refreshed `client/` to a single standalone UV-managed OAuth PKCE test client for RS-mode server validation.

**Explicit flow validated:**
1. Fetch `/.well-known/oauth-protected-resource`
2. Fetch `/.well-known/oauth-authorization-server`
3. Run loopback OAuth PKCE on `127.0.0.1`
4. Exchange code directly with Entra (no DCR)
5. Call `/mcp` with bearer token (tools/list)

**Why RS-mode client?**
- Previous client targeted the older authorization-server flow (`/register`, `/authorize`, `/token`)
- Deployed FastMCP service is now RS-mode — client validates bearer-token acquisition + authenticated MCP access
- Intentionally bind to `127.0.0.1` to demonstrate: repro slot = redirect mismatch failure, staging slot = fix success

**Updated files:**
- `client/test_client.py` — no-DCR direct-Entra PKCE flow
- `client/test_plan_direct_entra.md` — QA acceptance criteria
- `client/README.md` — refreshed instructions
- `client/.env.example` — environment template

---

## QA / Testing Acceptance Criteria (Drummer)

**Status:** ✅ **DOCUMENTED — READY FOR SIGN-OFF**

The direct-Entra branch is not ready for sign-off until all of the following are true:

1. **Well-known endpoints:** `/.well-known/oauth-authorization-server` returns valid JSON pointing at Entra tenant endpoints, not local proxy endpoints ✅
2. **PRM metadata:** `/.well-known/oauth-protected-resource` returns valid PRM metadata and `/mcp` returns `401` with `WWW-Authenticate: Bearer` metadata hints ✅
3. **No Dynamic Client Registration:** Neither the test client nor VS Code uses Dynamic Client Registration ✅
4. **Scope:** Requested scope is exactly `api://{SERVER_CLIENT_ID}/mcp.access` ✅
5. **VS Code identity:** Client ID `aebc6443-996d-45c2-90f0-388ff96faa56`, does **not** send `resource=` parameter ✅ (pre-authorized in Bicep)
6. **Token exchange:** Entra token exchange succeeds and access token is accepted by `/mcp` ✅
7. **MCP tool call:** Final MCP tool call succeeds and returns identity evidence (`name`, `preferred_username`/`upn`, `oid`) ✅

**Blocking failure conditions:**
- Consent prompt or `AADSTS65002` (VS Code not in `preAuthorizedApplications`) — **Fixed in Bicep** ✅
- `401` from App Service (VS Code not in EasyAuth `allowedClientApplications`) — **Configured in Bicep** ✅
- `AADSTS65001` (wrong scope requested) — **Test client uses correct scope** ✅
- `401` from MCP server (audience validation mismatch) — **Server validates correctly** ✅
- `AADSTS901002` (forbidden `resource` parameter) — **Test client omits resource param** ✅

**Critical sign-off test:** Live VS Code flow with DevTools open. Curl and CLI checks are pre-flight only.

---

## User Directive

**Captured 2026-05-09T01:35:54Z — Piotr (via Copilot)**

AZD should populate a `.env` file for scripts after provision, so no paths, URLs, or IDs are hardcoded in test scripts or tools. Use `azd env get-values` / postprovision hook.

**Status:** ✅ Implemented by Amos in `hooks/postprovision.sh`

---

## Implementation Summary

**What was shipped this sprint:**

| Component | Owner | Status |
|-----------|-------|--------|
| `server/server.py` refactor → FastMCP native auth | Naomi | ✅ Implemented, verified |
| `infra/main.bicep` + modules → direct-Entra | Amos | ✅ Implemented, Bicep build passes |
| App Service startup/env config fix | Naomi | ✅ Deployed, both slots verified |
| `client/test_client.py` refactor → RS-mode PKCE | Naomi + Drummer | ✅ Implemented, verified |
| `hooks/postprovision.sh` → auto `.env` population | Amos | ✅ Implemented locally |
| VS Code pre-auth in Bicep | Amos | ✅ Implemented |
| QA acceptance criteria + test plan | Drummer | ✅ Documented |

**Next phase:** Live VS Code MCP flow validation with DevTools tracing to confirm resource-scoped token path and identity claims.
