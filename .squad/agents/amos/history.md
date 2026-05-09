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

## Key Learnings

### Infrastructure & Bicep

- ARM JSON is auto-generated from Bicep compilation; Bicep is the canonical source
- Always use `az bicep build --file infra/main.bicep` (not bare `bicep` binary) on this machine
- Bicep 0.42.1 requires OCI extension reference for MS Graph: `br:mcr.microsoft.com/bicep/extensions/microsoftgraph/v1.0:0.1.8-preview`
- `subscription().tenantId` available at deployment time — eliminates operator input and AZD prompts
- App Service config collisions: Cannot have two `Microsoft.Web/sites/config` resources with same `name: 'appsettings'`
- AZD service discovery: Tag App Service with `azd-service-name: server` matching `azure.yaml` service name

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
