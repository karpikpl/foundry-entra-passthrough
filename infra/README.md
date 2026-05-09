# infra/README.md — AZD + Bicep Setup Guide
<!-- Created: 2026-05-09T04:22:42Z -->
<!-- Supersedes: scripts/provision-two-app-regs.sh (kept as fallback) -->

## Overview

This project uses **Azure Developer CLI (AZD)** + **Bicep** to provision:

| Resource | Module |
|---|---|
| Two Entra app registrations (repro + fixed) | `infra/modules/appRegistrations.bicep` |
| App Service `cloud-helper-fastmcp` (Python 3.12) | `infra/modules/appService.bicep` |
| Staging slot | `infra/modules/appService.bicep` |
| App Service Plan (B1, reused or new) | `infra/modules/appService.bicep` |

### Slot assignment (LOCKED — Piotr directive 2026-05-09)

| Slot | App Registration | Redirect URIs |
|---|---|---|
| **production** | `cloud-helper-mcp-repro` | `http://localhost` only ← H1 bug preserved |
| **staging** | `cloud-helper-mcp-fixed` | `http://localhost` + `http://127.0.0.1` ← H1 fixed |

Sticky settings (`CLIENT_ID`, `AUDIENCE`, `RESOURCE_HOST`, `AZURE_TENANT_ID`) ensure a slot swap **never** silently changes which app registration is active.

---

## Prerequisites

```bash
# Check versions (min: AZD 1.9+, Bicep 0.26+, az CLI 2.60+)
azd version
az bicep version
az version
```

### Entra permissions required

The user (or service principal) running `azd provision` must have:

- **Application.ReadWrite.OwnedBy** on Microsoft Graph (to create and own app registrations)
- **Contributor** on the resource group `rg-cloud-helper-mcp`

If you get a `Application.ReadWrite.All` permission error during provisioning, your admin needs to grant your account the **Application Developer** or **Application Administrator** role in Entra.

---

## One-time setup

```bash
# 1. Authenticate with AZD (opens browser)
azd auth login

# 2. Create a new AZD environment
azd env new cloud-helper-fastmcp

# 3. Set required environment values
azd env set AZURE_TENANT_ID      <your-entra-tenant-guid>
azd env set AZURE_SUBSCRIPTION_ID <your-subscription-id>
azd env set AZURE_LOCATION       eastus

# 4. (OPTIONAL) Reuse the existing App Service Plan from cloud-helper-mcp
#    If omitted, a new B1 plan is created.
azd env set EXISTING_PLAN_NAME   <existing-plan-name>
#    Find the plan name:
#    az appservice plan list --resource-group rg-cloud-helper-mcp --query "[].name" -o tsv
```

---

## Provision infrastructure (Bicep)

```bash
# Deploy all Bicep templates — creates app regs + App Service + slots
azd provision
```

On success, AZD prints the output values. You can also retrieve them later:

```bash
azd env get-values
```

---

## Deploy app code

```bash
# Deploy the FastMCP Python server to the App Service
azd deploy
```

AZD discovers the correct App Service via the `azd-service-name: server` tag set in Bicep.

---

## Repro → Fixed slot swap (code rollout only)

```bash
# Swap production ↔ staging (deploys fixed code to production, sends repro code to staging)
# Auth profiles stay with their slots (sticky settings).
az webapp deployment slot swap \
  --name cloud-helper-fastmcp \
  --resource-group rg-cloud-helper-mcp \
  --slot staging \
  --target-slot production
```

> ⚠️ After swap: production still has CLIENT_ID/AUDIENCE for the **repro** app registration (sticky). This is intentional — slot swap is for **code** rollout only. To change the auth profile, update the sticky app settings directly.

---

## Optional: Post-provision identifierUris fix

The MS Graph Bicep extension cannot set `identifierUris` to `api://{appId}` in the same resource block (self-referential). Bicep uses `api://cloud-helper-mcp-repro` and `api://cloud-helper-mcp-fixed` instead (valid and unique).

If you need the canonical `api://{appId}` format, run after provisioning:

```bash
# Get app IDs from AZD env
REPRO_ID=$(azd env get-values | grep REPRO_CLIENT_ID | cut -d= -f2 | tr -d '"')
FIXED_ID=$(azd env get-values | grep FIXED_CLIENT_ID | cut -d= -f2 | tr -d '"')

az ad app update --id "$REPRO_ID" --identifier-uris "api://${REPRO_ID}"
az ad app update --id "$FIXED_ID" --identifier-uris "api://${FIXED_ID}"

# Then update the AUDIENCE sticky settings on both slots
az webapp config appsettings set \
  --name cloud-helper-fastmcp \
  --resource-group rg-cloud-helper-mcp \
  --slot-settings "AUDIENCE=api://${REPRO_ID}/mcp.access"

az webapp config appsettings set \
  --name cloud-helper-fastmcp \
  --resource-group rg-cloud-helper-mcp \
  --slot staging \
  --slot-settings "AUDIENCE=api://${FIXED_ID}/mcp.access"
```

---

## Teardown

```bash
azd down
```

> ⚠️ This deletes the App Service and slots but does **not** delete Entra app registrations. Delete those manually via the Azure Portal or:
> ```bash
> az ad app delete --id <REPRO_CLIENT_ID>
> az ad app delete --id <FIXED_CLIENT_ID>
> ```

---

## Fallback: bash script

`scripts/provision-two-app-regs.sh` remains available as a fallback. It uses `az` CLI instead of Bicep and covers the same provisioning steps. See `scripts/README.md` for usage.
