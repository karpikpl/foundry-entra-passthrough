# Amos — Infrastructure / DevOps

## Project Context

- **Owner:** Piotr Karpala
- **Project:** mcp-oauth — debugging and fixing an OAuth 2.0 authorization_code + PKCE flow on an MCP server (Azure Web App). After Entra login, the client never POSTs to /token — the token exchange hangs.
- **Stack:** MCP server (Azure Web App `cloud-helper-mcp`), Microsoft Entra ID, Azure AI Foundry (`foundry-kvmorale`), VS Code MCP client, OAuth 2.0 PKCE
- **Azure Resources:** cloud-helper-mcp (RG: rg-cloud-helper-mcp, Sub: Cloud Brokers - ASC Testing), foundry-kvmorale (RG: kvmorale_Apr-16-2026, Sub: hosting-ai-sandbox)
- **Created:** 2026-05-08

## Recent Work Summary

### Round 9: ARM Cleanup & Bicep Parameter Fixes (2026-05-09)

**amos-8 — Remove tenantId parameter, derive from subscription()  
Commit:** 523f3d0

- Removed `param tenantId string` from `infra/main.bicep`
- Added `var tenantId = subscription().tenantId` (available at deployment time)
- Removed `tenantId` from `infra/main.parameters.json` (eliminates AZD prompt)
- Verification: `bicep build infra/main.bicep` → exit 0, no errors
- **Decision logged:** D13

**amos-9 — Add ARM JSON artifacts to .gitignore with main.parameters.json exception  
Commit:** b485692

- Added `infra/*.json` and `infra/**/*.json` to `.gitignore` (all compiled ARM templates are derived)
- Exception: `!infra/main.parameters.json` (AZD parameter file; must be tracked)
- Deleted `infra/main.json` from repository
- Verification: `bicep build infra/main.bicep` → exit 0, no errors
- **Decision logged:** D14

### Round 10: New AZD Environment + Entra Naming Parametrization (2026-05-11)

**amos-10a — Create new AZD environment `mcp-auth-test-direct`  
Status:** READY FOR DEPLOYMENT (awaiting `azd up`)

- Created AZD environment: `azd env new mcp-auth-test-direct`
- Set Azure subscription, location, resource group, tenant ID, app name, and plan parameters
- Environment directory: `.azure/mcp-auth-test-direct/`
- Verification: `az bicep build --file infra/main.bicep --stdout >/dev/null` → exit 0
- **Decision logged:** D16
- **Did NOT run:** `azd up` (pending D18 user constraint confirmation)

**amos-10b — Parametrize Entra app registration names with environment suffix  
Commit:** b8e27d5 (from spawn manifest)

- Updated `infra/modules/appRegistrations.bicep` to append `environmentName` to `displayName` and `uniqueName`
- Removed production special case (uniform naming across all environments)
- New app registration names for `mcp-auth-test-direct`:
  - Repro: `cloud-helper-mcp-repro-mcp-auth-test-direct`
  - Fixed: `cloud-helper-mcp-fixed-mcp-auth-test-direct`
- Verification: `az bicep build --file infra/main.bicep --stdout >/dev/null` → exit 0
- **Decision logged:** D17

## Key Learnings

### Infrastructure & Bicep

- ARM JSON is auto-generated from Bicep compilation; Bicep is the canonical source
- Always use `az bicep build --file infra/main.bicep` (not bare `bicep` binary) on this machine
- Bicep 0.42.1 requires OCI extension reference for MS Graph: `br:mcr.microsoft.com/bicep/extensions/microsoftgraph/v1.0:0.1.8-preview`
- `subscription().tenantId` available at deployment time — eliminates operator input and AZD prompts
- App Service config collisions: Cannot have two `Microsoft.Web/sites/config` resources with same `name: 'appsettings'`
- AZD service discovery: Tag App Service with `azd-service-name: server` matching `azure.yaml` service name
- **App Service SKU constraints:** Basic (B1) does NOT support deployment slots; must use Standard (S1) or above. Slots are required for blue/green and repro/fixed strategies.

### OAuth Architecture & Root Causes

**H1 (HIGH) — CONFIRMED:** Redirect URI mismatch
- Entra registration lists `http://localhost` (any port)
- Clients send `http://127.0.0.1:<port>/` (client behavior)
- Per RFC 8252 §8.3: These are **distinct** — loopback redirects MUST use `http://127.0.0.1` or `http://[::1]`

**H2 (HIGH) — CONFIRMED:** MCP clients don't use server's `/token` endpoint
- VS Code and AI Foundry obtain tokens directly from Entra (client-side OAuth)
- MCP server should act as Resource Server (RFC 9728 PRM), not Authorization Server
- Architecture fix: Remove `/authorize` and `/token` proxy endpoints; add `/.well-known/oauth-protected-resource`; validate Bearer tokens via JWT

**Cross-team validation:**
1. **Holden:** RFC 8252 theoretical analysis confirmed H1
2. **Naomi:** Code audit confirmed `test_oauth_client.py` binds to `127.0.0.1`
3. **Amos:** Entra config confirmed `http://127.0.0.1` not registered

### Tooling & Scripts Created

- **`scripts/fix-entra-redirect-uri.sh`** — Add `http://127.0.0.1` to redirect URIs (idempotent, dry-run mode)
- **`scripts/setup-entra-rs-mode.sh`** — RS-mode Entra app setup (idempotent, dry-run mode)
- **`scripts/provision-two-app-regs.sh`** — Two app registrations with repro/fixed variants; two slots
- **AZD + Bicep infrastructure** — `azure.yaml`, `infra/*.bicep`, `infra/modules/*.bicep`, `infra/README.md`

### User Directives (Approved)

- Reuse existing Foundry: `foundry-kvmorale` (Sub: hosting-ai-sandbox, RG: kvmorale_Apr-16-2026) — do NOT provision new instance
- Bicep compilation gate: Always run `bicep build infra/main.bicep` before marking infra tasks done (exit 0 required)
- Slot assignment: production = repro (H1 bug), staging = fixed (H1 corrected)

### Known Blockers & Open Items

- "Cloud Brokers - ASC Testing" subscription is in a different tenant — remediation scripts must be run by subscription owner (Valeria Morales / Intel team)
- Azure Web App IP restrictions block diagnostic probes from external IPs (secondary issue, not root cause)
- CORS verification on `cloud-helper-mcp` could not be completed (H6 unconfirmed)

## See Also

- **Full decisions:** `.squad/decisions.md` (D13, D14, and earlier OAuth analysis)
- **Archived history:** `history.archive.md` (detailed investigation notes from 2026-05-08)
- **Orchestration log:** `.squad/orchestration-log/20260509-045753-amos.md`

### Round 10: AZD-driven client .env generation (2026-05-09)

**amos-10 — Generate `client/.env` from AZD outputs and remove hardcoded test-client wiring**

- Added `hooks/postprovision.sh` and wired `azure.yaml` `postprovision` hook so AZD can write `client/.env` after `azd provision`
- Hook reads `azd env get-values`, derives server URLs and audience prefixes, writes `client/.env`, and prints the exact file contents
- Updated `client/test_client.py` to load `client/.env` via `python-dotenv` while preserving hardcoded fallbacks for local-only runs
- Added `python-dotenv>=1.0` to `client/pyproject.toml`, refreshed `client/uv.lock`, and gitignored `client/.env`
- Backfilled missing local AZD env outputs with `azd env set ...` from current resource-group deployments, then ran the hook immediately so Piotr has a working `client/.env` now

**Commands run:**

```bash
az bicep build --file infra/main.bicep
azd env get-values
az account show --query '{name:name,id:id,tenantId:tenantId}' -o json
az group show -n rg-mcp-auth-test --query '{name:name,location:location,id:id}' -o json
az deployment group list -g rg-mcp-auth-test --query "sort_by([].{name:name,timestamp:properties.timestamp}, &timestamp)[-5:]" -o json
az deployment group show -g rg-mcp-auth-test -n appRegistrations-mcp-auth-test --query 'properties.outputs' -o json
az deployment group show -g rg-mcp-auth-test -n appService-mcp-auth-test --query 'properties.outputs' -o json
chmod +x hooks/postprovision.sh
azd env set AZURE_TENANT_ID c29d6c2b-f765-41b3-b2a2-971a14239dfd
azd env set WEB_APP_NAME cloud-helper-fastmcp
azd env set REPRO_CLIENT_ID 52e5e7ea-ba6a-4d66-91a3-785d2edc4d43
azd env set FIXED_CLIENT_ID 7810abd8-ed7b-40f4-a447-04cc1658eab6
azd env set REPRO_AUDIENCE api://cloud-helper-mcp-repro-mcp-auth-test/mcp.access
azd env set FIXED_AUDIENCE api://cloud-helper-mcp-fixed-mcp-auth-test/mcp.access
./hooks/postprovision.sh
cd client && uv sync
cd client && uv run python test_client.py --help
az bicep build --file infra/main.bicep
```

## Learnings

- Direct-Entra Bicep support works with `Microsoft.Graph/applications@v1.0` plus `api.preAuthorizedApplications`; `delegatedPermissionIds` must use the exposed scope GUID, not the scope value string.
- App Service EasyAuth v2 for MCP should use `unauthenticatedClientAction: 'Return401'`, the tenant-specific `https://login.microsoftonline.com/{tenantId}/v2.0` issuer, token store enabled, and slot-specific `WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES`.
- Removing the proxy app registration also means removing `PROXY_CLIENT_*` assumptions from AZD hooks; postprovision only needs the MCP server app IDs/audiences and can ensure their service principals exist.
- Parallel AZD environments need a per-environment `WEB_APP_NAME`; Entra app registrations already suffix off `environmentName`, but App Service names are globally unique and must not stay hardcoded.
- For the direct-Entra clone of `mcp-auth-test`, `mcp-auth-test-direct` + `rg-mcp-auth-test-direct` + `cloud-helper-fastmcp-direct` cleanly separate the new rollout from the existing OAuthProxy-backed deployment.
- Entra app registration `displayName` values must always include `environmentName`; do not special-case `production`, or parallel AZD environments can drift back into shared names in the same tenant.
- `.azure/<env>/.env` only needs `AZURE_ENV_NAME` set because `infra/main.parameters.json` already maps that value into the Bicep `environmentName` parameter.
- FastMCP can own MCP auth end-to-end without App Service EasyAuth; removing `authsettingsV2` keeps `/.well-known/oauth-protected-resource` publicly reachable while `/mcp` still rejects anonymous calls.
- Keep `WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES` in slot app settings until Naomi confirms it is irrelevant to PRM content.
- `AZD_DEPLOY_SERVER_SLOT_NAME` can live in the AZD environment itself (`azd env set ...`) so `azd up`/`azd deploy` target the right slot without extra hooks or shell wrappers.
- With direct-Entra FastMCP, Bicep can own app registrations, slot wiring, and tenant-local service-principal creation; the old pre/post-provision hook scripts are unnecessary once proxy-era logic is gone.
- `azd up` can still time out even when App Service deploy succeeds if the app returns `404` on `/`; adding lightweight unauthenticated `/` and `/health` `200` probes makes AZD's runtime wait succeed while leaving PRM + `/mcp` auth behavior unchanged.

## 2026-05-11 — Direct-Entra Infrastructure Sprint Close

**Date:** 2026-05-11T13:07:59Z  
**Session:** direct-entra-implementation  
**Scribe:** Scribe Agent  
**Status:** ✅ COMPLETE

### Delivered

1. **Bicep Refactor for Direct-Entra**
   - Removed proxy client app registration from appRegistrations.bicep
   - Added api.preAuthorizedApplications for VS Code (aebc6443...) on fixed app
   - Configured EasyAuth v2 on both prod/staging slots
   - Set issuer to https://login.microsoftonline.com/{tenantId}/v2.0
   - Added allowedClientApplications for VS Code
   - Simplified hooks (preprovision → no-op, postprovision → bootstrap only)
   - Verification: bicep build ✅, shell syntax ✅

2. **AZD Environment Population**
   - Implemented hooks/postprovision.sh to auto-generate client/.env
   - Reads azd env get-values for tenant, client IDs, server URLs
   - Generates .env with REPRO/FIXED slot environments
   - client/test_client.py loads via python-dotenv with fallback
   - Verification: hook runs successfully, .env generated ✅

3. **Infrastructure Validation**
   - Audited Bicep outputs, slot config, app registrations
   - Confirmed redirect URIs, pre-authorization setup
   - No manual portal work needed for pre-auth (Bicep Graph resource handles)

### Key Decision

Bicep now owns EasyAuth + pre-auth configuration. Direct-Entra token validation integrated at deployment time.

### Files

- infra/main.bicep (refactored)
- infra/modules/appRegistrations.bicep (removed proxy, added VS Code pre-auth)
- infra/modules/appService.bicep (EasyAuth v2)
- infra/main.parameters.json (removed proxy secrets)
- hooks/postprovision.sh (AZD .env automation)

### Blockers

None identified. All Bicep changes validated and ready for next AZD provision.

### Next

Monitor slot deployments during AZD runs. Verify EasyAuth token validation + PRM metadata in staging.

### Round 11: `azd up` deployment result for `mcp-auth-test-direct` (2026-05-11)

- Ran `azd env select mcp-auth-test-direct` followed by `azd up --no-prompt` from repo root.
- `azd provision` succeeded far enough to create the S1 App Service plan, production site `cloud-helper-fastmcp-direct`, and the `staging` slot, plus both environment-scoped Entra app registrations.
- `azd up` then failed during `azd deploy` with: `deployment slots detected but no target specified. Set AZD_DEPLOY_SERVER_SLOT_NAME to one of: [production, staging] ('production' = main app)`.
- `azd show` still reported the production URL as `https://cloud-helper-fastmcp-direct.azurewebsites.net/` and `az webapp show` confirmed the site is running, but smoke tests were unhealthy because the app deploy step never completed.
- Smoke test results after the failed deploy: production `/.well-known/oauth-protected-resource` returned HTTP 503 Application Error; production `/.well-known/oauth-authorization-server`, production `/health`, and the same staging endpoints timed out.
- EasyAuth configuration exists on both slots (`az webapp auth show`), so no extra portal-only EasyAuth knob was identified in this pass; the blocking issue is the missing AZD slot target for deploy.
- Existing recommended VS Code MCP entry points at the fixed slot URL: `https://cloud-helper-fastmcp-direct-staging.azurewebsites.net/mcp`.

### 2026-05-11 — Cleanup Sprint: Deployment Success (D7)

**Date:** 2026-05-11T15:10:26.063-04:00  
**Decision:** D7 (merged into decisions.md)  
**Commit:** `56e12a7`  
**Environment:** `mcp-auth-test-direct` (rg-mcp-auth-test-direct)

**What happened:** Achieved successful `azd up` deployment with all infrastructure corrections applied. Both production and staging slots are now healthy and passing smoke tests.

**Infrastructure Corrections Applied:**
1. **Removed AZD Hooks** — deleted `hooks/preprovision.sh` and `hooks/postprovision.sh`
2. **Moved Entra SP Creation to Bicep** — tenant-local creation now in `infra/modules/appRegistrations.bicep`
3. **Removed EasyAuth Settings** — stripped from `infra/modules/appService.bicep`; disabled on live slots via `az resource update`
4. **Fixed App Service Plan Naming** — now derives from `webAppName` (`asp-<webAppName>`) instead of hardcoded
5. **Added Health Routes** — `/` and `/health` return 200 so `azd up` runtime probe completes

**Deploy Timeline:**
- **Attempt 1:** Provisioning ✅, but deployment timed out (production returned 404 on `/`)
- **Fix:** Added 200 responses on `/` and `/health`
- **Attempt 2:** `azd up -e mcp-auth-test-direct --no-prompt` → **SUCCESS ✅**
- **Staging Deploy:** `AZD_DEPLOY_SERVER_SLOT_NAME=staging azd deploy server` → **SUCCESS ✅**
- **Environment Config:** Set `AZD_DEPLOY_SERVER_SLOT_NAME=production` for future defaults

**Smoke Tests:**

| Slot | PRM Discovery | Auth Enforcement | Health |
|------|---------------|------------------|--------|
| Production | ✅ 200 | ✅ 401 | ✅ 200 |
| Staging | ✅ 200 | ✅ 401 | ✅ 200 |

**App Registrations:**
- Production: `cloud-helper-mcp-repro-mcp-auth-test-direct` (6e4f7931-...)
- Staging: `cloud-helper-mcp-fixed-mcp-auth-test-direct` (75e2a38e-...)

**Result:** Infrastructure fully declarative. Deployment repeatable. Both slots healthy and production-ready.

**Impact:** Builds on Naomi's server cleanup (simplified code enables deployment) and verified by Drummer's E2E tests. Completes cleanup sprint deployment domain.
