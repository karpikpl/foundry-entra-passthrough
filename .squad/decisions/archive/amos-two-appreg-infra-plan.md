# Amos plan — two Entra app registrations + App Service slots

**Date:** 2026-05-08T23:04:39.683-04:00  
**By:** Amos (Infra / DevOps)  
**Requested by:** Piotr Karpala  
**Status:** READY TO RUN

---

## Executive call

**Recommendation: choose (b) — create a NEW App Service for the FastMCP RS-mode server, with a `staging` slot.**

Why:
- `cloud-helper-mcp` is the legacy app and already has IP restrictions (`403 Ip Forbidden` from `70.231.17.250`).
- The legacy app source is not in this repo; the new FastMCP RS-mode server **is** in this repo.
- Repro/fixed work should be isolated from the legacy service until Piotr confirms the new deployment.
- Slots still give us side-by-side repro/fixed deployment, without inheriting legacy allowlist pain.

**Important slot nuance:** if `CLIENT_ID` / `AZURE_CLIENT_ID` is marked as a **slot setting (sticky)**, a slot swap does **not** move that setting to production. That is the right safety choice, but it means **slot swap is not the mechanism that changes app registration**. Use slots for side-by-side hosting; switch the live registration by updating the production slot's sticky settings after validation.

---

## What I could and could not verify from this machine

I checked local `az` access. Current session does **not** have the target subscriptions visible:
- `Cloud Brokers - ASC Testing` → not visible
- `hosting-ai-sandbox` → not visible

So this playbook is written to be run by someone logged into the correct tenant/subscription. First commands below verify access before making changes.

**CLI prerequisites on the operator machine:** `az`, `jq`, `python3`

---

## Assumptions locked in from team decisions

- **H1 confirmed:** bug is `http://localhost` registered, client sends `http://127.0.0.1:<port>/`.
- **H2 confirmed:** server must run in **RS-mode** and publish `/.well-known/oauth-protected-resource`.
- **Do not provision new Foundry.** Reuse `foundry-kvmorale`.
- New server code in this repo uses these env vars:
  - `TENANT_ID`
  - `CLIENT_ID`
  - `AUDIENCE`
  - `RESOURCE_HOST`
  - `PORT`
- Existing Azure Web App may already use `AZURE_CLIENT_ID` / `AZURE_TENANT_ID`; for transition, set both names to the same values if needed.

---

## Exact Entra registration design

### 1) `repro` registration
Use this to reproduce H1.

**Display name:** `cloud-helper-mcp-repro`  
**Platform mix:**
- **Public client** for loopback testing
- **Web** for Foundry / VS Code redirect URIs already seen in the email chain

**Exact redirect URIs:**
- **Public client redirect URIs**
  - `http://localhost`
  - **Do NOT add** `http://127.0.0.1`
- **Web redirect URIs**
  - `https://foundry.azure.com/`
  - `https://vscode.dev/redirect`

**Other settings:**
- `signInAudience=AzureADMyOrg`
- `isFallbackPublicClient=true`
- No client secret
- Also expose API for RS-mode:
  - Application ID URI = `api://<client_id>`
  - Scope = `mcp.access`
  - `requestedAccessTokenVersion=2`

### 2) `fixed` registration
Use this for the correct configuration.

**Display name:** `cloud-helper-mcp-fixed`  
**Platform mix:** same as above.

**Exact redirect URIs:**
- **Public client redirect URIs**
  - `http://localhost`
  - `http://127.0.0.1`
- **Web redirect URIs**
  - `https://foundry.azure.com/`
  - `https://vscode.dev/redirect`

**RS-mode / resource-server settings:**
- Application ID URI = `api://<client_id>`
- Delegated scope = `api://<client_id>/mcp.access`
- `requestedAccessTokenVersion=2`
- Enterprise app / service principal created for the registration

---

## Step 0 — preflight: log into the right tenant and verify subscription access

```bash
set -euo pipefail

export TARGET_SUB="Cloud Brokers - ASC Testing"
export TARGET_RG="rg-cloud-helper-mcp"
export EXISTING_APP="cloud-helper-mcp"
export NEW_APP="cloud-helper-fastmcp"
export SLOT="staging"

# Log in to the tenant that owns Cloud Brokers - ASC Testing
az login --tenant "<tenant-guid-or-domain>"

# Verify the target subscription is now visible
az account list --output table | grep -E "Cloud Brokers - ASC Testing|hosting-ai-sandbox" || true

# Set the app-hosting subscription
az account set --subscription "$TARGET_SUB"

# Verify existing app/resource group are visible
az group show --name "$TARGET_RG" --output table
az webapp show --resource-group "$TARGET_RG" --name "$EXISTING_APP" --output table
```

If those fail, stop and fix tenant/subscription access first.

---

## Step 1 — helper function: configure RS-mode API exposure on an app registration

```bash
configure_rs_api() {
  local app_obj_id="$1"
  local client_id="$2"
  local scope_value="mcp.access"
  local scope_id
  local scope_json

  scope_id="$(python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
)"

  scope_json="$(SCOPE_ID="$scope_id" python3 - <<'PY'
import json, os
print(json.dumps([
  {
    "id": os.environ["SCOPE_ID"],
    "adminConsentDisplayName": "Access FastMCP server",
    "adminConsentDescription": "Allows the app to access the FastMCP server on behalf of the signed-in user",
    "userConsentDisplayName": "Access FastMCP server",
    "value": "mcp.access",
    "type": "User",
    "isEnabled": True
  }
], separators=(",", ":")))
PY
)"

  az ad app update --id "$app_obj_id" \
    --identifier-uris "api://$client_id" \
    --requested-access-token-version 2

  az ad app update --id "$app_obj_id" \
    --set "api.oauth2PermissionScopes=$scope_json"

  # Ensure enterprise app exists
  az ad sp create --id "$client_id" --only-show-errors >/dev/null || true
}
```

---

## Step 2 — create the `repro` app registration

```bash
export REPRO_APP_NAME="cloud-helper-mcp-repro"

REPRO_JSON="$(az ad app list \
  --filter "displayName eq '$REPRO_APP_NAME'" \
  --query '[0].{objId:id,clientId:appId,displayName:displayName}' \
  --output json)"

if [[ "$(echo "$REPRO_JSON" | jq -r '.objId // empty')" == "" ]]; then
  REPRO_JSON="$(az ad app create \
    --display-name "$REPRO_APP_NAME" \
    --sign-in-audience AzureADMyOrg \
    --is-fallback-public-client true \
    --public-client-redirect-uris "http://localhost" \
    --web-redirect-uris "https://foundry.azure.com/" "https://vscode.dev/redirect" \
    --query '{objId:id,clientId:appId,displayName:displayName}' \
    --output json)"
fi

export REPRO_APP_OBJ_ID="$(echo "$REPRO_JSON" | jq -r '.objId')"
export REPRO_CLIENT_ID="$(echo "$REPRO_JSON" | jq -r '.clientId')"

echo "REPRO_APP_OBJ_ID=$REPRO_APP_OBJ_ID"
echo "REPRO_CLIENT_ID=$REPRO_CLIENT_ID"

configure_rs_api "$REPRO_APP_OBJ_ID" "$REPRO_CLIENT_ID"

az ad app update --id "$REPRO_APP_OBJ_ID" \
  --is-fallback-public-client true \
  --public-client-redirect-uris "http://localhost" \
  --web-redirect-uris "https://foundry.azure.com/" "https://vscode.dev/redirect"

az ad app show --id "$REPRO_APP_OBJ_ID" \
  --query '{displayName:displayName,publicClientRedirectUris:publicClient.redirectUris,webRedirectUris:web.redirectUris,identifierUris:identifierUris,scopes:api.oauth2PermissionScopes[].value,requestedAccessTokenVersion:api.requestedAccessTokenVersion}' \
  --output yaml
```

**Expected result:**
- `publicClient.redirectUris` contains **only** `http://localhost`
- no `http://127.0.0.1`
- app exposes `api://$REPRO_CLIENT_ID/mcp.access`

---

## Step 3 — create the `fixed` app registration

```bash
export FIXED_APP_NAME="cloud-helper-mcp-fixed"

FIXED_JSON="$(az ad app list \
  --filter "displayName eq '$FIXED_APP_NAME'" \
  --query '[0].{objId:id,clientId:appId,displayName:displayName}' \
  --output json)"

if [[ "$(echo "$FIXED_JSON" | jq -r '.objId // empty')" == "" ]]; then
  FIXED_JSON="$(az ad app create \
    --display-name "$FIXED_APP_NAME" \
    --sign-in-audience AzureADMyOrg \
    --is-fallback-public-client true \
    --public-client-redirect-uris "http://localhost" "http://127.0.0.1" \
    --web-redirect-uris "https://foundry.azure.com/" "https://vscode.dev/redirect" \
    --query '{objId:id,clientId:appId,displayName:displayName}' \
    --output json)"
fi

export FIXED_APP_OBJ_ID="$(echo "$FIXED_JSON" | jq -r '.objId')"
export FIXED_CLIENT_ID="$(echo "$FIXED_JSON" | jq -r '.clientId')"

echo "FIXED_APP_OBJ_ID=$FIXED_APP_OBJ_ID"
echo "FIXED_CLIENT_ID=$FIXED_CLIENT_ID"

configure_rs_api "$FIXED_APP_OBJ_ID" "$FIXED_CLIENT_ID"

az ad app update --id "$FIXED_APP_OBJ_ID" \
  --is-fallback-public-client true \
  --public-client-redirect-uris "http://localhost" "http://127.0.0.1" \
  --web-redirect-uris "https://foundry.azure.com/" "https://vscode.dev/redirect"

az ad app show --id "$FIXED_APP_OBJ_ID" \
  --query '{displayName:displayName,publicClientRedirectUris:publicClient.redirectUris,webRedirectUris:web.redirectUris,identifierUris:identifierUris,scopes:api.oauth2PermissionScopes[].value,requestedAccessTokenVersion:api.requestedAccessTokenVersion}' \
  --output yaml
```

**Expected result:**
- `publicClient.redirectUris` contains both `http://localhost` and `http://127.0.0.1`
- app exposes `api://$FIXED_CLIENT_ID/mcp.access`

---

## Step 4 — App Service slot check on the EXISTING app (read-only)

Run this first, even if taking the new-app recommendation.

```bash
az webapp deployment slot list \
  --resource-group "$TARGET_RG" \
  --name "$EXISTING_APP" \
  --output table

az webapp config access-restriction show \
  --resource-group "$TARGET_RG" \
  --name "$EXISTING_APP" \
  --output yaml
```

**Interpretation:**
- If `staging` is absent, the existing app has no staging slot.
- If access restrictions show explicit allow rules / default deny, they are the reason this machine got `403 Ip Forbidden`.

---

## Step 5 — recommended path: create a NEW App Service for FastMCP and add `staging`

### 5a. Reuse the existing App Service plan

```bash
export APP_SERVICE_PLAN_ID="$(az webapp show \
  --resource-group "$TARGET_RG" \
  --name "$EXISTING_APP" \
  --query serverFarmId \
  --output tsv)"

export APP_SERVICE_PLAN_NAME="$(basename "$APP_SERVICE_PLAN_ID")"

echo "APP_SERVICE_PLAN_NAME=$APP_SERVICE_PLAN_NAME"
```

### 5b. Create the new FastMCP app

```bash
az webapp show --resource-group "$TARGET_RG" --name "$NEW_APP" --output none 2>/dev/null || \
az webapp create \
  --resource-group "$TARGET_RG" \
  --plan "$APP_SERVICE_PLAN_NAME" \
  --name "$NEW_APP" \
  --runtime "PYTHON:3.12"
```

### 5c. Create the staging slot if missing

```bash
az webapp deployment slot show \
  --resource-group "$TARGET_RG" \
  --name "$NEW_APP" \
  --slot "$SLOT" \
  --output none 2>/dev/null || \
az webapp deployment slot create \
  --resource-group "$TARGET_RG" \
  --name "$NEW_APP" \
  --slot "$SLOT" \
  --configuration-source "$NEW_APP"
```

---

## Step 6 — app settings that control which app registration the server uses

### Shared settings (same on both slots)

These are safe to keep non-sticky:
- `TENANT_ID`
- `PORT`
- deployment/runtime settings (`SCM_DO_BUILD_DURING_DEPLOYMENT`, etc.)

```bash
export TENANT_ID="<tenant-guid>"

az webapp config appsettings set \
  --resource-group "$TARGET_RG" \
  --name "$NEW_APP" \
  --settings \
    TENANT_ID="$TENANT_ID" \
    PORT=8000 \
    SCM_DO_BUILD_DURING_DEPLOYMENT=true

az webapp config appsettings set \
  --resource-group "$TARGET_RG" \
  --name "$NEW_APP" \
  --slot "$SLOT" \
  --settings \
    TENANT_ID="$TENANT_ID" \
    PORT=8000 \
    SCM_DO_BUILD_DURING_DEPLOYMENT=true
```

### Sticky slot settings (slot-specific)

These **must** be slot settings:
- `CLIENT_ID`
- `AUDIENCE`
- `RESOURCE_HOST`
- optional compatibility duplicates: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`

**Production slot = repro**

```bash
az webapp config appsettings set \
  --resource-group "$TARGET_RG" \
  --name "$NEW_APP" \
  --slot-settings \
    CLIENT_ID="$REPRO_CLIENT_ID" \
    AUDIENCE="api://$REPRO_CLIENT_ID" \
    RESOURCE_HOST="$NEW_APP.azurewebsites.net" \
    AZURE_CLIENT_ID="$REPRO_CLIENT_ID" \
    AZURE_TENANT_ID="$TENANT_ID"
```

**Staging slot = fixed**

```bash
az webapp config appsettings set \
  --resource-group "$TARGET_RG" \
  --name "$NEW_APP" \
  --slot "$SLOT" \
  --slot-settings \
    CLIENT_ID="$FIXED_CLIENT_ID" \
    AUDIENCE="api://$FIXED_CLIENT_ID" \
    RESOURCE_HOST="$NEW_APP-$SLOT.azurewebsites.net" \
    AZURE_CLIENT_ID="$FIXED_CLIENT_ID" \
    AZURE_TENANT_ID="$TENANT_ID"
```

### Slot behavior answer

- **Yes:** `CLIENT_ID` / `AZURE_CLIENT_ID` should be **sticky**.
- **Also yes:** `RESOURCE_HOST` should be sticky, because production and staging have different hostnames.
- **Result:** slot swap does **not** change which app registration production uses.
- **Therefore:** use slot swap for code rollout, but use **appsettings update** to flip production from repro → fixed.

### Explicit cutover command (recommended)

When Piotr is ready to make production use the fixed registration:

```bash
az webapp config appsettings set \
  --resource-group "$TARGET_RG" \
  --name "$NEW_APP" \
  --slot-settings \
    CLIENT_ID="$FIXED_CLIENT_ID" \
    AUDIENCE="api://$FIXED_CLIENT_ID" \
    RESOURCE_HOST="$NEW_APP.azurewebsites.net" \
    AZURE_CLIENT_ID="$FIXED_CLIENT_ID" \
    AZURE_TENANT_ID="$TENANT_ID"
```

If code also needs to move from staging to production, do the swap separately:

```bash
az webapp deployment slot swap \
  --resource-group "$TARGET_RG" \
  --name "$NEW_APP" \
  --slot "$SLOT" \
  --target-slot production
```

---

## Step 7 — IP allowlisting answer

### Recommended answer

**If we create the NEW FastMCP App Service, do not copy the legacy allowlist initially.**

Reason:
- we want a clean repro/fixed environment
- the legacy app already blocks diagnostics from this machine
- Foundry / VS Code access should be validated first without inherited restrictions

### If security policy requires allowlisting even on the new app

Add Piotr's current public IP to both the main site and SCM site:

```bash
export DEV_IP="70.231.17.250/32"

az webapp config access-restriction add \
  --resource-group "$TARGET_RG" \
  --name "$NEW_APP" \
  --rule-name "piotr-current-ip" \
  --ip-address "$DEV_IP" \
  --priority 200

az webapp config access-restriction add \
  --resource-group "$TARGET_RG" \
  --name "$NEW_APP" \
  --rule-name "piotr-current-ip-scm" \
  --ip-address "$DEV_IP" \
  --priority 200 \
  --scm-site true

az webapp config access-restriction add \
  --resource-group "$TARGET_RG" \
  --name "$NEW_APP" \
  --slot "$SLOT" \
  --rule-name "piotr-current-ip-staging" \
  --ip-address "$DEV_IP" \
  --priority 200

az webapp config access-restriction add \
  --resource-group "$TARGET_RG" \
  --name "$NEW_APP" \
  --slot "$SLOT" \
  --rule-name "piotr-current-ip-staging-scm" \
  --ip-address "$DEV_IP" \
  --priority 200 \
  --scm-site true
```

### If Piotr insists on using the EXISTING `cloud-helper-mcp`

Then yes: you must inspect and likely update access restrictions on:
- production slot main site
- production slot SCM site
- staging slot main site
- staging slot SCM site

Do **not** assume a new slot bypasses the existing allowlist.

---

## Step 8 — validation commands after deployment

### Validate Entra registrations

```bash
az ad app show --id "$REPRO_APP_OBJ_ID" \
  --query '{public:publicClient.redirectUris,web:web.redirectUris,idUri:identifierUris[0],scope:api.oauth2PermissionScopes[0].value}' \
  --output yaml

az ad app show --id "$FIXED_APP_OBJ_ID" \
  --query '{public:publicClient.redirectUris,web:web.redirectUris,idUri:identifierUris[0],scope:api.oauth2PermissionScopes[0].value}' \
  --output yaml
```

### Validate App Service slot settings

```bash
az webapp config appsettings list \
  --resource-group "$TARGET_RG" \
  --name "$NEW_APP" \
  --query "[?name=='CLIENT_ID' || name=='AUDIENCE' || name=='RESOURCE_HOST' || name=='TENANT_ID' || name=='AZURE_CLIENT_ID' || name=='AZURE_TENANT_ID'].{name:name,slotSetting:slotSetting,value:value}" \
  --output table

az webapp config appsettings list \
  --resource-group "$TARGET_RG" \
  --name "$NEW_APP" \
  --slot "$SLOT" \
  --query "[?name=='CLIENT_ID' || name=='AUDIENCE' || name=='RESOURCE_HOST' || name=='TENANT_ID' || name=='AZURE_CLIENT_ID' || name=='AZURE_TENANT_ID'].{name:name,slotSetting:slotSetting,value:value}" \
  --output table
```

### Validate the RS-mode metadata endpoint

```bash
curl -fsS "https://$NEW_APP.azurewebsites.net/.well-known/oauth-protected-resource" | jq .
curl -fsS "https://$NEW_APP-$SLOT.azurewebsites.net/.well-known/oauth-protected-resource" | jq .
```

Expected:
- `resource` matches the slot hostname
- `authorization_servers[0]` points to Entra tenant issuer
- `scopes_supported` includes `mcp.access`

---

## If Piotr wants to reuse the EXISTING App Service anyway

Use this instead of Step 5:

```bash
az webapp deployment slot show \
  --resource-group "$TARGET_RG" \
  --name "$EXISTING_APP" \
  --slot "$SLOT" \
  --output none 2>/dev/null || \
az webapp deployment slot create \
  --resource-group "$TARGET_RG" \
  --name "$EXISTING_APP" \
  --slot "$SLOT" \
  --configuration-source "$EXISTING_APP"
```

Then apply the same sticky settings logic from Step 6, but use:
- production `RESOURCE_HOST=cloud-helper-mcp.azurewebsites.net`
- staging `RESOURCE_HOST=cloud-helper-mcp-staging.azurewebsites.net`

**I do not recommend this path** because it inherits the legacy app's access restrictions and mixes legacy + new-server rollout.

---

## Bottom line

- Create **two** Entra app registrations: `cloud-helper-mcp-repro` and `cloud-helper-mcp-fixed`.
- Both are **RS-mode** resource-server registrations exposing `api://<client_id>/mcp.access`.
- The only intentional H1 difference is the loopback public-client redirect URIs:
  - repro = `http://localhost` only
  - fixed = `http://localhost` + `http://127.0.0.1`
- Use a **new** App Service (`cloud-helper-fastmcp`) with a `staging` slot.
- Keep `CLIENT_ID` / `AZURE_CLIENT_ID` **sticky**; flip production to fixed with an **appsettings update**, not with slot swap alone.
