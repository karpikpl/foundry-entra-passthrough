# Project Context

- **Owner:** Piotr Karpala
- **Project:** mcp-oauth — debugging and fixing an OAuth 2.0 authorization_code + PKCE flow on an MCP server (Azure Web App). After Entra login, the client never POSTs to /token — the token exchange hangs.
- **Stack:** MCP server (Azure Web App `cloud-helper-mcp`), Microsoft Entra ID, Azure AI Foundry (`foundry-kvmorale`), VS Code MCP client, OAuth 2.0 PKCE
- **Azure Resources:** cloud-helper-mcp (RG: rg-cloud-helper-mcp, Sub: Cloud Brokers - ASC Testing), foundry-kvmorale (RG: kvmorale_Apr-16-2026, Sub: hosting-ai-sandbox)
- **Created:** 2026-05-08

## Learnings

### 2026-05-09T04:40:27Z — Bicep 0.42.1 Graph extension + App Service config fixes

- **Microsoft Graph extension fix:** Bicep 0.42.1 does not recognize the `builtin:` extension scheme. The working configuration is the OCI reference in `infra/bicepconfig.json`: `br:mcr.microsoft.com/bicep/extensions/microsoftgraph/v1.0:0.1.8-preview`.
- **Verification outcome:** `bicep build infra/main.bicep` succeeds with that OCI reference, so no AZD preprovision hook fallback was needed.
- **App Service config collision:** `Microsoft.Web/sites/config` resources under the same parent cannot both use `name: 'appsettings'`. The dedicated `webAppSettings` resource was redundant because `webAppStickyProd` already carried the shared settings.
- **Cleanup:** Removed the unused `environmentName` parameter from `infra/modules/appService.bicep` and the redundant module-level `dependsOn` from `infra/main.bicep`.

### 2026-05-08T17:46:22Z — Cross-Agent Finding: Root cause analysis (from Holden) + User directive

**H1 (HIGH): Redirect URI mismatch** — Entra app registration may list `http://localhost` (any port), but Entra's actual redirect lands on `http://127.0.0.1:<port>/`. Per RFC 8252, loopback redirects MUST use `http://127.0.0.1` or `http://[::1]` — NOT `http://localhost`. If app registration platform type is "Web" vs "Mobile/Desktop", port matching behavior differs. Need to verify exact registered URIs and platform type.

**H5 (MEDIUM): Platform type and port matching** — If app registration platform is "Web", it requires exact URI match (scheme, host, port). If it's "Mobile/Desktop", it allows `http://localhost` with any port. This changes how Entra validates the redirect.

**Action items for Amos:**
1. Pull Entra app registration: `az ad app show` for exact redirect URIs (including scheme, host, port)
2. Confirm platform type: Web vs. Mobile/Desktop
3. Check if `http://127.0.0.1` is registered IN ADDITION to `http://localhost`
4. Verify Azure Web App CORS settings: `az webapp cors show` on `cloud-helper-mcp`
5. Check Entra token endpoint configuration (v1 vs v2) and conditional access policies

**User directive (APPROVED):**
- Reuse existing Foundry: `foundry-kvmorale` (Sub: hosting-ai-sandbox, RG: kvmorale_Apr-16-2026)
- **Do NOT provision new Azure AI Foundry instance**
- Investigation tests against existing foundry

**See:** `.squad/decisions.md` for full hypothesis list

### 2026-05-08T17:46:22Z: Entra config audit completed — redirect URI mismatch confirmed as root cause

**Source:** `issue.md` + `issue-report.md` (customer-documented URIs) + `client/test_oauth_client.py` (client behavior)

- The Entra app registration for `cloud-helper-mcp` has **`http://localhost`** registered (with implied "any port" / Mobile and desktop applications platform). `http://127.0.0.1` is **NOT registered**.
- The test client and all MCP clients bind their callback listener to `127.0.0.1` and send `http://127.0.0.1:<port>/` as `redirect_uri` in `/authorize`. This URI is not in the Entra registration.
- Per RFC 8252 §8.3 and Entra's matching rules, `localhost` and `127.0.0.1` are **distinct** — dynamic-port allowance on `http://localhost` does not extend to `http://127.0.0.1`.
- **H1 (HIGH)** is confirmed as the primary root cause. **H5** may be a secondary issue depending on platform type (Web vs. Mobile/Desktop) — needs direct CLI verification.
- **CORS (H6):** Could not verify — `rg-cloud-helper-mcp` is not accessible from current CLI context. Manual check required.

**Fix:** Add `http://127.0.0.1` to the "Mobile and desktop applications" platform redirect URIs in the Entra app registration:
```bash
az ad app update --id <APP_ID> --public-client-redirect-uris "http://localhost" "http://127.0.0.1"
```

**CLI blocker:** "Cloud Brokers - ASC Testing" subscription is in a different tenant, not accessible from current `az` session. All remediation commands must be run by the subscription owner (Valeria Morales / Intel team). Full command set documented in `.squad/decisions/inbox/amos-entra-config-audit.md`.

### 2026-05-08T18:02:01Z — Remediation script written

**Script:** `scripts/fix-entra-redirect-uri.sh`  
**Docs:** `scripts/README.md`

**What the script does:**
- Adds `http://127.0.0.1` to the public-client (Mobile/Desktop) redirect URIs of the Entra app registration, preserving existing URIs
- Looks up the app by display name (defaults to `cloud-helper-mcp`) or by object ID via `--app-id`
- Accepts `--tenant-id` and `--subscription` params — no hardcoded values

**Key design decisions:**
- **Idempotent:** reads current URIs first; exits cleanly if target URI already present
- **Prereq checks:** validates `az` CLI installed + user logged in before any reads
- **Dry-run mode** (`--dry-run`): prints the `az ad app update` command it would run, makes no changes
- **Verification step:** re-reads the app registration after update and confirms the URI is present (with a 2s replication delay buffer)
- **No hardcoded tenant/subscription:** all identity context passed as params or derived from current `az` session
- **Transparent output:** ✅/❌/⚠️ indicators throughout; prints before/after URI lists

**CLI blocker (unchanged):** The "Cloud Brokers - ASC Testing" subscription is in a different tenant from the current dev machine's `az` session. Piotr or Valeria must run the script from a session logged into that tenant.

### 2026-05-08T17:50:48Z — CROSS-AGENT CONFIRMATION: H1 Validated by 3 Independent Sources

**H1 (HIGH) is now CONFIRMED:**
1. **Holden (Analysis):** RFC 8252 §8.3 — `127.0.0.1` ≠ `localhost`
2. **Naomi (Code Audit):** Confirmed in `client/test_oauth_client.py` — binds to `127.0.0.1`
3. **Amos (Entra Config):** Confirmed in app registration — `http://localhost` registered, `http://127.0.0.1` missing

**Secondary finding (IP Allowlisting from Naomi):**
- Azure Web App blocks external IPs (70.231.17.250 returns 403)
- Not the cause of OAuth hang but should be addressed for diagnostic access

**Fix command ready:** `az ad app update --id <APP_ID> --public-client-redirect-uris "http://localhost" "http://127.0.0.1"`  
**Execution status:** Awaiting execution in "Cloud Brokers - ASC Testing" tenant

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

### 2026-05-08T22:48:54Z — RS-mode Entra Setup Script Written

**Script:** `scripts/setup-entra-rs-mode.sh`  
**Docs:** Updated `scripts/README.md` with RS-mode guidance  
**Decision:** `.squad/decisions/inbox/amos-entra-rs-mode-script.md`

**What it does:**
- Creates or reuses Entra app registration for RS-mode (Resource Server)
- Sets Application ID URI: `api://{client_id}`
- Defines OAuth2 delegated permission scope: `mcp.access`
- Configures token version v2 (required for Bearer token validation)
- Accepts params: `--tenant-id`, `--subscription`, `--app-name`, `--dry-run`
- Idempotent: safe to run multiple times
- Dry-run mode: shows what would happen without making changes

**Key insight:** This is fundamentally different from `fix-entra-redirect-uri.sh`. The redirect URI fix handles H1 (test clients). RS-mode setup handles the production architecture (H2 root cause). Clients don't use the server's `/token` endpoint — they get tokens directly from Entra and POST them as Bearer tokens. The server validates tokens via JWT inspection.

**Architecture:** RFC 9728 (Protected Resource Model). VS Code and AI Foundry already implement this — they obtain tokens from Entra and send Bearer tokens to protected APIs. No redirect flow, no `/token` endpoint on server.

**Usage order:**
1. Run RS-mode setup first (`setup-entra-rs-mode.sh`)
2. Optionally run redirect URI fix (`fix-entra-redirect-uri.sh`) if testing with loopback clients

**Next step:** Server-side implementation must validate Bearer tokens using JWT inspection middleware. This completes the RS-mode architecture.

### 2026-05-09T04:11:47Z — Consolidated provisioning script written

**Script:** `scripts/provision-two-app-regs.sh`
**Docs:** Updated `scripts/README.md` with full section for the new script
**Decision:** `.squad/decisions/inbox/amos-provision-script-complete.md`

**What the script does (end-to-end runnable):**
- Step 0: Preflight — az/jq/python3 check, subscription set, RG verify
- Step 1: `configure_rs_api` helper function — RS-mode setup (identifier URI, mcp.access scope, token v2)
- Step 2: Idempotent create/verify `cloud-helper-mcp-repro` (public-client: `http://localhost` only)
- Step 3: Idempotent create/verify `cloud-helper-mcp-fixed` (public-client: `http://localhost` + `http://127.0.0.1`)
- Step 4: Read-only inspect of legacy `cloud-helper-mcp` (slots + access restrictions)
- Step 5: Create `cloud-helper-fastmcp` App Service (reuse existing plan) + staging slot
- Step 6: Shared non-sticky settings (TENANT_ID, PORT=8000, SCM_DO_BUILD_DURING_DEPLOYMENT=true)
- Step 7: Sticky slot settings — production→REPRO, staging→FIXED
- Step 8: Validation reads (app reg URIs/scopes, slot appsettings)
- Step 9: Commented-out cutover command to flip production to FIXED when ready
- Summary with test sequence printed at end

**Slot assignment locked (Piotr directive):**
- production = `cloud-helper-mcp-repro` (H1 bug preserved)
- staging = `cloud-helper-mcp-fixed` (H1 corrected)

**Design notes:**
- `set -euo pipefail` throughout
- `--dry-run` flag: reads still execute, writes printed via `dryrun()`
- Idempotent: `az ad app list --filter` before create; `az webapp show` before create; slot show before create
- `configure_rs_api` preserves existing scope GUID across re-runs (no stale duplicate scopes)
- Sticky settings applied with `--slot-settings` (not `--settings`) so swap never silently changes auth profile
- Style consistent with existing scripts (color helpers, same function signatures)

### 2026-05-09T04:22:42Z — AZD + Bicep migration completed

**Decision:** `.squad/decisions/inbox/amos-azd-bicep-migration.md`

**Files created:**
- `azure.yaml` — AZD project root; binds `server/` (Python) to appservice host `cloud-helper-fastmcp`
- `infra/bicepconfig.json` — enables `microsoftGraphV1` Bicep extension
- `infra/main.bicep` — orchestrator calling appRegistrations + appService modules
- `infra/main.parameters.json` — AZD env var bindings (`AZURE_ENV_NAME`, `AZURE_TENANT_ID`, `AZURE_LOCATION`, `EXISTING_PLAN_NAME`)
- `infra/modules/appRegistrations.bicep` — two Entra app regs via `Microsoft.Graph/applications@v1.0`
- `infra/modules/appService.bicep` — App Service + staging slot + sticky settings
- `infra/README.md` — operator runbook (`azd auth login` → `azd env new` → `azd provision` → `azd deploy`)
- `scripts/provision-two-app-regs.sh` — updated header to mark as superseded (kept as fallback)

**Key learnings:**
- **MS Graph Bicep identifierUris limitation:** `Microsoft.Graph/applications@v1.0` cannot self-reference `appId` within the same resource block to form `api://{appId}`. Used `api://cloud-helper-mcp-repro` / `api://cloud-helper-mcp-fixed` pattern instead (display-name based, valid and unique). Documented a post-provision `az ad app update` step for teams needing canonical format.
- **MS Graph Bicep requires permission:** deploying principal needs `Application.ReadWrite.OwnedBy` on MS Graph; without it, `azd provision` fails on the Graph resources. Document this clearly.
- **AZD service discovery:** tag App Service with `azd-service-name: server` matching `azure.yaml` service name — AZD finds it automatically, no hardcoded resource name in `azd deploy`.
- **Existing plan reuse:** handled via optional `existingPlanName` parameter with `existing` resource reference — conditional on whether the param is empty.
- **Scope GUIDs:** used Bicep `guid()` function (deterministic, input-based) for `oauth2PermissionScopes[].id` — stable across re-deploys for the same env.

**Slot assignment (unchanged from D9, Piotr directive):**
- production = repro (H1 bug preserved)
- staging = fixed (H1 corrected)

### 2026-05-08T23:04:39.683-04:00 — Two-app-registration infra playbook completed

**Decision:** `.squad/decisions/archive/amos-two-appreg-infra-plan.md`

- Wrote the operator playbook to provision **repro** and **fixed** Entra app registrations with `api://<client_id>/mcp.access` exposed on both.
- Recommended a new `cloud-helper-fastmcp` App Service with a `staging` slot to isolate the RS-mode rollout from the legacy app.
- Declared `CLIENT_ID`, `AUDIENCE`, `RESOURCE_HOST`, `AZURE_CLIENT_ID`, and `AZURE_TENANT_ID` as sticky slot settings.
- Proposed mapping: production slot = repro, staging slot = fixed; slot swap is not the main auth-profile switch.
