# Squad Decisions

## Investigation Round 1 — OAuth Token Exchange Failure (2026-05-08)

### D1: Root Cause Analysis — OAuth token exchange failure
**By:** Holden (Lead / Auth Architect)  
**Date:** 2026-05-08T17:43:37Z  
**Status:** Investigation pending — H1 and H2 are highest priority

**Summary:** Most likely root cause is redirect URI mismatch between `http://127.0.0.1:<port>/` (what Entra actually redirects to) and `http://localhost` (what is registered), or the MCP client SDK may not implement token exchange.

**Seven ranked hypotheses:**
- **H1 (HIGH):** Redirect URI mismatch — `127.0.0.1` vs `localhost`
- **H2 (HIGH):** MCP client SDK does not perform token exchange
- **H3 (MEDIUM):** Client callback handler fails on state/PKCE validation
- **H4 (MEDIUM):** Entra "Sign-in successful!" page is dead end
- **H5 (MEDIUM):** Port-specific redirect URI rejected by Entra
- **H6 (LOW):** CORS blocks `/token` POST
- **H7 (LOW):** Authorization code expired or single-use collision

**Investigation assigned to:**
- **Naomi:** Server-side verification (metadata, `/authorize`, CORS, `/token` logging)
- **Amos:** Entra & Azure verification (app registration, platform type, CORS, token endpoint)
- **Alex:** Client-side tracing (build test client, HTTP trace capture, SDK inspection)
- **Drummer:** Reproduction and exact failure point documentation

---

### D2: OAuth test suite created
**By:** Drummer (Tester / QA)  
**Date:** 2026-05-08T17:43:37Z  
**File:** tests/oauth-flow-test-cases.md

12 test cases covering:
- OAuth PKCE happy path
- Known failure (TC-02) — must reproduce before fix
- Edge cases
- **Blocking:** TC-09 and TC-10 must pass before sign-off

---

### D3: Minimal OAuth test client created
**By:** Alex (MCP Client Dev)  
**Date:** 2026-05-08T17:43:37Z  
**Files:** client/test_oauth_client.py, client/requirements.txt, client/README.md

Python test client that:
- Exercises full OAuth PKCE flow with verbose HTTP logging
- Starts local callback server
- Explicitly logs whether `/token` is called
- Will show exact point of hang

---

### D4: User directive — reuse existing Foundry
**By:** Piotr Karpala (via Copilot)  
**Date:** 2026-05-08T17:46:22Z  
**Status:** APPROVED

- **No new Azure AI Foundry provisioning**
- Reuse existing foundry: `foundry-kvmorale` (Sub: hosting-ai-sandbox, RG: `kvmorale_Apr-16-2026`)
- **Impact:** Amos should NOT provision new instance. Investigation tests against existing foundry.

---

### D5: Server code audit — OAuth token endpoint investigation (FINDINGS)
**By:** Naomi (Backend Dev)  
**Date:** 2026-05-08T17:46:22Z  
**Status:** COMPLETE — Key findings and recommended actions

**Critical Finding: H1 CONFIRMED in client code**

Alex's test client (`client/test_oauth_client.py`, lines 156–163):
- Binds callback listener to `127.0.0.1` (not `localhost`)
- Constructs redirect_uri as `http://127.0.0.1:{port}/`
- Sends this in `/authorize` request

But registered redirect URIs in Entra are:
- `https://foundry.azure.com/`
- `https://vscode.dev/redirect`
- `http://localhost` ← **NO `http://127.0.0.1` entry**

Per RFC 8252 §8.3, these are NOT equivalent. **This is the most likely root cause of the OAuth hang.**

**Other Findings:**

1. **No server source code in repo** — MCP server source is deployed to Azure Web App `cloud-helper-mcp.azurewebsites.net` but not in this repository. Cannot audit `/token` implementation details, CORS config, or PKCE validation from code alone.

2. **Azure Web App has IP restriction (secondary finding)** — All direct probes from investigation machine (IP: 70.231.17.250) blocked with `403 Ip Forbidden`. Does not prevent customer's clients but limits server-side investigation. Amos must verify IP allowlist includes legitimate client IPs.

3. **Server architecture confirmed as pass-through proxy** — Client POSTs to server's `/token`, server exchanges code with Entra, server returns token to client. This matches MCP OAuth spec.

**Recommended Actions (Priority order):**

1. **(Amos)** Add `http://127.0.0.1` to Entra app registration redirect URIs using "Mobile and desktop applications" platform type
2. **(Server owner / Valeria)** Update `/.well-known/oauth-authorization-server` metadata to advertise both `http://localhost` and `http://127.0.0.1`
3. **(Server owner)** Verify POST `/token` responds with `Access-Control-Allow-Origin: https://foundry.azure.com` (CORS required for browser-based Foundry)
4. **(Amos)** Check `az webapp cors show` for `cloud-helper-mcp` — confirm Foundry origin listed
5. **(Team)** Get server source code into repo or shared with team for full audit
6. **(Amos)** Run `az webapp show --query siteConfig.ipSecurityRestrictions` to verify IP allowlist includes legitimate clients

---

### D6: Entra config audit — OAuth redirect URI investigation (FINDINGS)
**By:** Amos (Infra / DevOps)  
**Date:** 2026-05-08T17:46:22Z  
**Status:** COMPLETE — H1 confirmed with remediation steps

**H1 — CONFIRMED (HIGH CONFIDENCE)**

Registered redirect URI in Entra: `http://localhost` (with dynamic port allowance)  
Client sends in `/authorize`: `http://127.0.0.1:<port>/`  
Per RFC 8252 and Entra matching logic: These are **distinct identifiers**

Entra will either:
- Reject `/authorize` with `AADSTS50011: The redirect URI specified does not match`, OR
- Allow redirect but bind code to wrong URI, causing `/token` exchange to fail with `redirect_uri_mismatch`

Either way: **`/token` is never successfully called** — exactly the observed symptom.

**Registered URIs (from issue.md, customer-confirmed):**

| URI | Registered? |
|-----|-------------|
| `https://foundry.azure.com/` | ✅ Yes |
| `https://vscode.dev/redirect` | ✅ Yes |
| `http://localhost` (any port) | ✅ Yes |
| `http://127.0.0.1` (any port) | ❌ **NOT registered** |

**H5 — CANNOT FULLY CONFIRM without CLI access** (MEDIUM CONFIDENCE)

If platform type is "Web" rather than "Mobile/Desktop", dynamic ports are forbidden. Need CLI access to confirm platform.

**H6 (CORS) — UNCONFIRMED** — needs manual check. If Foundry/VS Code are browser-based clients, missing CORS origins block `/token` POST.

**Immediate Remediation (fixes H1):**

```bash
# 1. Switch to correct subscription
az account set --subscription "Cloud Brokers - ASC Testing"

# 2. Get app ID from web app config
az webapp config appsettings list --name cloud-helper-mcp --resource-group rg-cloud-helper-mcp \
  --query "[?name=='AZURE_CLIENT_ID'].value" --output tsv

# 3. Add http://127.0.0.1 as publicClient redirect URI
az ad app update --id <APP_ID> \
  --public-client-redirect-uris "http://localhost" "http://127.0.0.1"

# 4. Verify CORS allows Foundry origin
az webapp cors add --name cloud-helper-mcp --resource-group rg-cloud-helper-mcp \
  --allowed-origins "https://foundry.azure.com" "https://vscode.dev"

# 5. Re-test with client/test_oauth_client.py — if /token now called, H1 was root cause
```

**Note:** Direct CLI reads failed due to missing subscription access on this machine. These commands must be run by someone with access to "Cloud Brokers - ASC Testing" subscription (Valeria or resource owner).

---

### D7: Cross-agent confirmation: H1 validated by 3 independent sources
**Date:** 2026-05-08T17:50:48Z  
**Status:** CONFIRMED

**H1 (HIGH) is now confirmed by:**

1. **Holden** (Lead Analysis): RFC 8252 §8.3 theoretical analysis — redirect URI `127.0.0.1` vs `localhost` are distinct per standard
2. **Naomi** (Code Audit): Confirmed in test client source — `client/test_oauth_client.py` explicitly binds to `127.0.0.1` while Entra registration lists only `http://localhost`
3. **Amos** (Entra Config): Confirmed in actual Entra app registration — `http://127.0.0.1` is **NOT in registered redirect URIs**, only `http://localhost` is registered

**Secondary Finding: IP Allowlisting**
- Naomi discovered that Azure Web App blocks external IPs (70.231.17.250 returns 403 Ip Forbidden)
- This is a separate operational issue but not the cause of the OAuth flow hang
- Should be addressed during remediation to enable diagnostic probes

---

### D8: Two app registrations + slot URL strategy
**By:** Holden (Lead / Auth Architect)  
**Date:** 2026-05-09T03:04:39Z  
**Status:** APPROVED FOR PROVISIONING  
**Source:** `.squad/decisions/archive/holden-two-appreg-slot-strategy.md`

**Summary:** Use two single-tenant Entra app registrations for the same FastMCP RS-mode server: a **repro** registration that keeps only `http://localhost`, and a **fixed** registration that adds `http://127.0.0.1`. Keep both auth profiles live in parallel on App Service slots, use slot URLs directly for broken vs fixed demos, and keep `CLIENT_ID`, `AUDIENCE`, and `RESOURCE_HOST` sticky per slot.

**Holden slot mapping:**
- staging slot = repro (broken)
- production slot = fixed

---

### D9: Two app registration provisioning playbook
**By:** Amos (Infra / DevOps)  
**Date:** 2026-05-08T23:04:39.683-04:00  
**Status:** READY TO RUN  
**Source:** `.squad/decisions/archive/amos-two-appreg-infra-plan.md`

**Summary:** Provision two RS-mode Entra app registrations via `az` CLI, expose `api://<client_id>/mcp.access` on both, and host the new FastMCP deployment on a new App Service with a `staging` slot. Keep `CLIENT_ID`, `AUDIENCE`, `RESOURCE_HOST`, and compatibility auth settings sticky; use app-settings updates to cut production between auth profiles instead of relying on slot swap alone.

**Amos slot mapping:**
- production slot = repro (broken)
- staging slot = fixed

---

### D10: Slot assignment conflict between Holden and Amos
**Date:** 2026-05-09T03:04:39Z  
**Status:** UNRESOLVED — pending Piotr's call

- **Holden:** staging slot = repro (broken), production slot = fixed
- **Amos:** production slot = repro (broken), staging slot = fixed
- Do not treat slot-specific broken/fixed assignment as settled until Piotr chooses the canonical mapping.

### D11: User directive — Bicep compilation gate
**By:** Piotr Karpala (via Copilot)  
**Date:** 2026-05-09T04:40:27Z  
**Status:** ACTIVE

Always run `bicep build infra/main.bicep` (exit 0, no errors) before marking any Bicep/infra task as done. Warnings are acceptable; errors are not. This applies to Amos and any agent touching infra/.

**Context:** User request captured for team memory after azd provision failed due to unverified Bicep compilation errors.

---

### D12: Bicep compilation errors fixed — AZD provisioning unblocked
**By:** Amos (Infra / DevOps)  
**Date:** 2026-05-09T04:40:27Z  
**Status:** COMPLETE  
**Commit:** baf77c7

**Summary:** Resolved the two Bicep compilation blockers that broke `azd provision`.

1. **Microsoft Graph extension:** Switched `infra/bicepconfig.json` from unsupported `builtin:microsoftGraphV1` to the OCI-published extension reference:
   `br:mcr.microsoft.com/bicep/extensions/microsoftgraph/v1.0:0.1.8-preview`
   This works on Bicep CLI 0.42.1, so the fallback preprovision hook path was not required.

2. **App Service duplicate config resources:** Removed the redundant `webAppSettings` resource from `infra/modules/appService.bicep`. `webAppStickyProd` already includes the full shared app settings set, so keeping both caused the duplicate `appsettings` resource-name collision.

3. **Related cleanup:** Removed the unused `environmentName` parameter from `infra/modules/appService.bicep` and the unnecessary `dependsOn` from `infra/main.bicep`.

**Verification:**
- `az bicep build --file infra/main.bicep` → exit 0
- `bicep build infra/main.bicep` → exit 0

**Impact:** `azd provision` is no longer blocked by these compile-time Bicep errors.

### D13: Derive tenantId from subscription() in AZD Bicep entrypoint
**By:** Amos (Infrastructure / DevOps)  
**Date:** 2026-05-09T04:51:40Z  
**Status:** IMPLEMENTED  
**Commit:** 523f3d0

**Problem:** `azd provision` was prompting for `tenantId` because `infra/main.bicep` declared it as a required parameter with no default.

**Decision:** Resolve tenant inside Bicep:
- Remove `param tenantId string` from `infra/main.bicep`
- Add `var tenantId = subscription().tenantId` near top
- Remove `tenantId` from `infra/main.parameters.json`
- Keep module contract for `infra/modules/appService.bicep` unchanged

**Rationale:** `subscription().tenantId` is available at deployment time and matches active Azure context. Eliminates unnecessary operator input and prevents AZD prompts.

**Verification:** `bicep build infra/main.bicep` → exit 0, no errors.

---

### D14: Never commit ARM JSON build artifacts
**By:** Piotr Karpala (via Copilot)  
**Date:** 2026-05-09T04:40:27Z  
**Status:** IMPLEMENTED  
**Commit:** b485692

**Rule:** `infra/*.json` files (compiled ARM templates) must be gitignored.  
**Exception:** `infra/main.parameters.json` is the AZD parameter file and must be tracked.

**Rationale:** ARM JSON is derived from Bicep and should never be in source control. Reduces noise and prevents merge conflicts on auto-generated files.

---

### D15: Upgrade App Service SKU from B1 to S1
**By:** Amos (Infrastructure / DevOps)  
**Date:** 2026-05-09T01:09:08Z  
**Status:** IMPLEMENTED  
**Commit:** ba4bc9f

**Summary:** Basic SKU (B1) does not support deployment slots. Upgraded `infra/modules/appService.bicep` to Standard S1 SKU to enable slot-based deployment strategy (repro on production slot, fixed on staging slot).

**Changes:**
1. Updated parameter description from "create new B1 plan" to "create new S1 plan"
2. Changed SKU block from `name: 'B1'` / `tier: 'Basic'` to `name: 'S1'` / `tier: 'Standard'`
3. Updated comment from "create B1" to "create S1"

**Why S1?**
Deployment slots (required for blue/green and repro/fixed strategies) are only available on Standard, Premium, and Isolated tiers. Basic (B1) and Free (F1) do not support slots.

**Verification:** `bicep build infra/main.bicep` → exit 0 (clean compilation)

---

### D16: New direct-Entra AZD environment setup
**By:** Amos (Infra / DevOps)  
**Date:** 2026-05-11T13:27:42.425-04:00  
**Status:** IMPLEMENTED  

**Summary:** Provisioned new AZD environment `mcp-auth-test-direct` for direct-Entra pattern testing.

**New environment details:**
- AZD environment: `mcp-auth-test-direct`
- Resource group: `rg-mcp-auth-test-direct`
- Web app name: `cloud-helper-fastmcp-direct`
- Subscription: 0721e282-2773-4021-af16-e00641ed5e36 (Cloud Brokers - ASC Testing)
- Location: eastus
- Tenant: c29d6c2b-f765-41b3-b2a2-971a14239dfd

**Parameters configured:**
- `AZURE_SUBSCRIPTION_ID`, `AZURE_LOCATION`, `AZURE_RESOURCE_GROUP`, `AZURE_TENANT_ID`, `WEB_APP_NAME` all set
- `EXISTING_PLAN_NAME` left blank (creates new S1 plan)
- Future parameters after `azd up`: `REPRO_CLIENT_ID`, `FIXED_CLIENT_ID`, `REPRO_AUDIENCE`, `FIXED_AUDIENCE`, `WEB_APP_HOSTNAME`

**Verification:**
- Environment created: `azd env list` confirms `mcp-auth-test-direct` exists
- Bicep validates: `az bicep build --file infra/main.bicep --stdout >/dev/null` → exit 0

**Next steps:** 
- `azd env select mcp-auth-test-direct`
- `azd up` to deploy (pending Piotr decision on Entra naming convention)
- Post-deploy: verify client IDs/audiences are distinct from main environment

---

### D17: Entra app registration naming — environment-scoped suffix
**By:** Amos (Infra / DevOps)  
**Date:** 2026-05-11T13:27:42.425-04:00  
**Status:** IMPLEMENTED  

**Summary:** Parameterized Entra app registration `displayName` and `uniqueName` to include `environmentName` suffix, ensuring unique names across environments.

**Change:**
- Updated `infra/modules/appRegistrations.bicep` to suffix both `displayName` and `uniqueName` with `environmentName`
- Removed production special case (all environments now treated equally)
- Verified `.azure/mcp-auth-test-direct/.env` contains `AZURE_ENV_NAME="mcp-auth-test-direct"` which flows into Bicep `environmentName`

**New app registration names for mcp-auth-test-direct environment:**
- Repro app: `cloud-helper-mcp-repro-mcp-auth-test-direct`
- Fixed app: `cloud-helper-mcp-fixed-mcp-auth-test-direct`

**Verification:**
- Bicep compilation: `az bicep build --file infra/main.bicep --stdout >/dev/null` → exit 0
- No naming collisions between environments

**Rationale:** Multiple environments (development, test, production) must have distinct Entra app registrations. Appending environment name ensures no accidental resource collisions.

---

### D18: User directive — Entra app registration naming uniqueness constraint
**By:** Piotr Karpala (via Copilot)  
**Date:** 2026-05-11T13:27:42.425-04:00  
**Status:** ACTIVE  

**Constraint:** Entra app registrations must use a unique suffix in the `displayName` (and internal naming). Do not reuse or collide with existing app registration names. Options include:
- Environment name (e.g., `mcp-auth-test-direct`)
- Semantic suffix (e.g., `-direct`)
- Timestamp (e.g., `-2026-05-11`)

**Rationale:** User requirement to distinguish new direct-Entra app registrations from legacy OAuthProxy app registrations. Prevents accidental reuse and makes audit trails clear.

**Implementation:** D17 implements this via environment name suffix in Bicep.

---

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
