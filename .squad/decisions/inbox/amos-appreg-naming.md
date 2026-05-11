# Amos — App Registration Naming

- **Date:** 2026-05-11T13:27:42.425-04:00
- **Requester:** pkarpala
- **Branch:** investigate/direct-entra-pattern
- **Status:** implemented

## What changed

- Reviewed `infra/main.bicep` and all files in `infra/modules/` to locate the Entra app registrations.
- Confirmed the `Microsoft.Graph/applications@v1.0` resources live in `infra/modules/appRegistrations.bicep`.
- Updated the app-registration naming logic so `displayName` and `uniqueName` always suffix `environmentName`.
- Removed the previous `production` special case so every environment gets distinct Entra names.
- Verified `.azure/mcp-auth-test-direct/.env` already contains `AZURE_ENV_NAME="mcp-auth-test-direct"`, which flows into Bicep `environmentName` via `infra/main.parameters.json`.

## New display names for mcp-auth-test-direct

- Repro app: `cloud-helper-mcp-repro-mcp-auth-test-direct`
- Fixed app: `cloud-helper-mcp-fixed-mcp-auth-test-direct`

## Commands run

```bash
git --no-pager branch --show-current
az bicep build --file infra/main.bicep --stdout > /dev/null
```
