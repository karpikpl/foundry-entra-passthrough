# Decisions Log

## 2026-05-09: UV Migration & AZD+Bicep Infrastructure

### D1: UV Migration for server/ and client/ (Naomi)

**Date:** 2026-05-09T04:22:42Z  
**Status:** COMPLETE

Migrated `server/` and `client/` from pip/venv to UV for dependency management, virtual environments, and script execution.

**Key Decisions:**
- `pyproject.toml` replaces `requirements.txt` as primary source; `requirements.txt` retained with DEPRECATED header as fallback
- Entry point is `server:main`, wrapping `uvicorn.run(app, ...)`
- App Service startup: `bash startup.sh` runs `uv run uvicorn server:app --host 0.0.0.0 --port ${PORT:-8080}`
- Dropped unused deps (`fastapi`, `python-dotenv`); Starlette via `mcp[cli]`, pydantic-settings native
- Client external dep: `requests` only
- Makefile at repo root for convenience (`make install`, `make dev`, `make client-run`)

**Files Changed:**
- `server/pyproject.toml`, `server/uv.lock`, `server/startup.sh` — CREATED
- `server/server.py`, `server/README.md`, `server/requirements.txt` — MODIFIED
- `client/pyproject.toml`, `client/uv.lock`, `client/README.md`, `client/requirements.txt` — CREATED/MODIFIED
- `Makefile` — CREATED (repo root)

---

### D2: AZD + Bicep Migration for Infra Provisioning (Amos)

**Date:** 2026-05-09T04:22:42Z  
**Status:** IMPLEMENTED

Migrated all Azure provisioning from bash script to AZD (Azure Developer CLI) + Bicep for repeatable, declarative infrastructure.

**Key Decisions:**
- `azd provision` → Bicep templates create Entra app regs + App Service + slots
- `azd deploy` → AZD deploys FastMCP Python server from `server/`
- Bash script retained as fallback, header updated
- Microsoft.Graph Bicep extension for Entra resources (declarative, idempotent)
- Identifier URIs: `api://cloud-helper-mcp-repro` (repro) and `api://cloud-helper-mcp-fixed` (fixed)
- Slot assignment: production=repro (H1 bug), staging=fixed (H1 corrected)
- Sticky settings on both slots: `CLIENT_ID`, `AUDIENCE`, `RESOURCE_HOST`, `AZURE_TENANT_ID`
- Optional existing App Service Plan reuse via `existingPlanName` parameter

**Files Created/Modified:**
- `azure.yaml` — AZD project config (binds `server/` to app service)
- `infra/bicepconfig.json` — MS Graph Bicep extension config
- `infra/main.bicep`, `infra/main.parameters.json` — Orchestrator + env bindings
- `infra/modules/appRegistrations.bicep`, `infra/modules/appService.bicep` — Resource modules
- `infra/README.md` — Operator runbook
- `scripts/provision-two-app-regs.sh` — Header updated to flag superseded

---

### D3: AZD Resolves Tenant/Subscription Automatically (Amos)

**Date:** 2026-05-09T04:33:30Z  
**Status:** CORRECTED

`azd` does **not** require manually setting `AZURE_SUBSCRIPTION_ID` or `AZURE_TENANT_ID` via `azd env set`. Both are resolved automatically from the authenticated session established by `azd auth login`.

**Key Corrections:**
- Removed manual `azd env set AZURE_TENANT_ID` and `azd env set AZURE_SUBSCRIPTION_ID` from infra runbook
- Only `AZURE_LOCATION` (and optional `EXISTING_PLAN_NAME`) remain as user-supplied values
- Updated `infra/main.bicep` tenant parameter description to reflect automatic resolution
- `infra/main.parameters.json` already correctly uses `${AZURE_TENANT_ID}` AZD binding

**Correct Setup Flow:**
```bash
azd auth login                         # resolves tenant + subscription
azd env new cloud-helper-fastmcp       # creates environment
azd env set AZURE_LOCATION eastus      # only user-supplied value required
azd provision                          # tenantId flows from AZURE_TENANT_ID automatically
```

**Files Modified:**
- `infra/README.md` — removed manual env set instructions
- `infra/main.bicep` — updated tenantId parameter description

---

## Summary

| Category | UV Migration | AZD+Bicep | AZD Auth |
|----------|--------------|-----------|----------|
| Status | COMPLETE | IMPLEMENTED | CORRECTED |
| Agent | Naomi | Amos | Amos |
| Python/Deps | pyproject.toml + uv.lock | N/A | N/A |
| Infra | N/A | Bicep (declarative) | Auth auto-resolution |
| Deployment | startup.sh | AZD + App Service | N/A |

---

## 2026-05-11: Cleanup Sprint — Documentation, Server Cleanup, Deployment Success

### D4: Documentation Trimmed to Minimal (Holden)

**Date:** 2026-05-11  
**Status:** COMPLETE

User feedback emphasized that verbose documentation was counterproductive. Trimmed all docs to essential facts and links.

**Key Changes:**
- `README.md` reduced to ~50 lines (was 140)
- Deleted `docs/architecture.md` (428 lines) — RFC 9728, FastMCP docs cover full details
- Deleted `docs/vscode-setup.md` (232 lines) — merged into README
- **Total:** 800 → 50 lines

**Philosophy:** Don't document what others have already documented. Point to authoritative sources (MS Learn, FastMCP GitHub, RFC 9728). Local docs answer only "How does our specific implementation differ?"

**Files Changed:**
- `README.md` — trimmed, links added
- `docs/architecture.md` — DELETED
- `docs/vscode-setup.md` — DELETED

---

### D5: Server Cleanup — Remove Dead Auth Code (Naomi)

**Date:** 2026-05-11T04:22:42Z  
**Status:** COMPLETE

Removed legacy authentication code and simplified server to single active path: FastMCP native auth (`RemoteAuthProvider` + `JWTVerifier` + PRM alias).

**Key Changes:**
- Deleted unused `server/auth.py` — no longer in request path
- Simplified `server/server.py` — kept only FastMCP native auth
- Simplified `server/config.py` — removed unused `CLIENT_SECRET`
- Updated `server/.env.example`, `server/README.md`
- Regenerated `server/requirements.txt` from `uv export`

**Decisions:**
1. Delete dead code instead of preserving for reference (reduces confusion)
2. Remove `CLIENT_SECRET` — direct-Entra pattern doesn't exchange auth codes server-side
3. `RESOURCE_APP_ID` remains for GUID-form `aud` claims compatibility

**Test Client Updates:**
- Added `--url` flag (alias: `--server-url`) for slot targeting
- Explicit RFC 9728 PRM discovery before auth
- Default target: fixed staging slot

**Verification:**
- `server:app` imports cleanly
- `test_client.py --help` runs
- No remnants of `OAuthProxy`, `EasyAuth`, or `CLIENT_SECRET` in `server/`

**Files Changed:**
- `server/auth.py` — DELETED
- `server/server.py`, `server/config.py` — simplified
- `server/requirements.txt` — regenerated
- `client/test_client.py` — added `--url` flag, PRM discovery
- Commit: `4f680e2`

---

### D6: No EasyAuth — FastMCP Native Auth Only (Naomi)

**Date:** 2026-05-11T04:22:42Z  
**Status:** VERIFIED

FastMCP 3.2.4 natively supports OAuth protected resources via `RemoteAuthProvider` + `JWTVerifier`. EasyAuth is not required and complicates the flow with 302 redirects and wrong token formats.

**Key Findings:**
- `auth.py` not in request path for FastMCP native auth
- FastMCP exposes `/.well-known/oauth-protected-resource/mcp` but not root `/.well-known/oauth-protected-resource`
- `POST /mcp` protected by `RequireAuthMiddleware` — returns `401` with `WWW-Authenticate` + `resource_metadata`
- PRM document advertises Entra as authorization server

**Server Changes:**
1. Added public root RFC 9728 alias at `/.well-known/oauth-protected-resource`
2. Broadened `JWTVerifier(audience=...)` to accept both:
   - App registration GUID (`aud` in issued tokens)
   - `api://...` identifier URI (for advertised scopes)

**Verification:**
- `GET /.well-known/oauth-protected-resource` → 200 JSON (no auth required)
- `GET /.well-known/oauth-protected-resource/mcp` → 200 JSON
- `POST /mcp` without `Authorization` → 401 (correct challenge)
- `POST /mcp` with invalid bearer → 401
- `POST /mcp` with Entra token lacking `mcp.access` → 401 (fails only scope validation)

---

### D7: Deployment Success — All Slots Healthy (Amos)

**Date:** 2026-05-11T19:04:03Z  
**Status:** COMPLETE

Achieved successful `azd up` deployment with all infrastructure corrections applied. Both production and staging slots are healthy and passing smoke tests.

**Environment:** `mcp-auth-test-direct` (rg-mcp-auth-test-direct)

**Infrastructure Changes:**
- Removed AZD hooks (`hooks/preprovision.sh`, `hooks/postprovision.sh`)
- Moved Entra SP creation into `infra/modules/appRegistrations.bicep`
- Removed leftover EasyAuth app settings from `infra/modules/appService.bicep`
- App Service plan name now derives from `webAppName` (`asp-<webAppName>`)
- Added `/.well-known/oauth-protected-resource` and `/health` unauthenticated routes for AZD runtime probe

**Deploy Timeline:**
1. Initial `azd up` succeeded in provisioning but timed out in AZD runtime wait (production returned 404)
2. Added `200` responses on `/` and `/health`
3. Reran `azd up -e mcp-auth-test-direct --no-prompt` → **SUCCESS**
4. Deployed to staging: `AZD_DEPLOY_SERVER_SLOT_NAME=staging azd deploy server -e mcp-auth-test-direct --no-prompt`
5. Set `AZD_DEPLOY_SERVER_SLOT_NAME=production` in AZD environment for future defaults

**Smoke Tests — Production** (`https://cloud-helper-fastmcp-direct.azurewebsites.net`)
- `GET /.well-known/oauth-protected-resource/mcp` → `200`
- `POST /mcp` without token → `401`
- `GET /` → `200`
- `GET /health` → `200`
- PRM scope: `api://cloud-helper-mcp-repro-mcp-auth-test-direct/mcp.access`

**Smoke Tests — Staging** (`https://cloud-helper-fastmcp-direct-staging.azurewebsites.net`)
- `GET /.well-known/oauth-protected-resource/mcp` → `200`
- `POST /mcp` without token → `401`
- PRM scope: `api://cloud-helper-mcp-fixed-mcp-auth-test-direct/mcp.access`

**App Registrations:**
- Repro: `cloud-helper-mcp-repro-mcp-auth-test-direct` (prod slot)
- Fixed: `cloud-helper-mcp-fixed-mcp-auth-test-direct` (staging slot)

**Commits:**
- `56e12a7` — all pending work, AZD hooks removed, SP moved to Bicep, EasyAuth stripped, azd up successful

---

### D8: Drummer E2E Auth Tests — FastMCP Native Flow Validated (Drummer)

**Date:** 2026-05-11T14:47:57.864-04:00  
**Status:** PASSED (Production)

End-to-end FastMCP-native auth smoke tests confirm that the direct-Entra pattern works correctly without EasyAuth. Production passes all checks; staging is recovered after slot health restoration.

**Test Results Summary:**
- ✅ Prod PRM discovery — `GET /.well-known/oauth-protected-resource/mcp` returns correct JSON
- ❌ Staging PRM discovery — returned `503` at test time (now fixed)
- ✅ Prod anonymous `/mcp` → `401` (correct rejection)
- ❌ Staging anonymous `/mcp` → `503` (now fixed)
- ✅ Prod `WWW-Authenticate` header includes `resource_metadata`
- ✅ Prod invalid bearer → `401`
- ⚠️ Python test client requires interactive browser auth to complete full E2E (functional, not headless-testable)

**Key Findings:**
- Production PRM advertises scope: `api://cloud-helper-mcp-repro-mcp-auth-test-direct/mcp.access`
- Production `WWW-Authenticate` includes `Bearer error="invalid_token", resource_metadata="..."`
- Test client correctly starts Entra `/authorize` flow and localhost callback listener (FastMCP native, not EasyAuth)

**Production URLs:**
- Base: `https://cloud-helper-fastmcp-direct.azurewebsites.net`
- Staging: `https://cloud-helper-fastmcp-direct-staging.azurewebsites.net`

**Tenant:** `c29d6c2b-f765-41b3-b2a2-971a14239dfd`

---

## Summary — 2026-05-11 Cleanup Sprint

| Item | Owner | Status | Notes |
|------|-------|--------|-------|
| Documentation trim | Holden | ✅ Complete | 800 → 50 lines; links to authoritative sources |
| Server cleanup | Naomi | ✅ Complete | `auth.py` removed; FastMCP native only; commit `4f680e2` |
| No EasyAuth | Naomi | ✅ Verified | RFC 9728 root alias added; dual audience support |
| Deployment success | Amos | ✅ Complete | `azd up` healthy; both slots passing smoke tests; commit `56e12a7` |
| E2E auth validation | Drummer | ✅ Passed | Production PRM + auth rejection working; staged slot healthy |
