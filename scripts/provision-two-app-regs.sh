#!/usr/bin/env bash
# provision-two-app-regs.sh
#
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  SUPERSEDED — 2026-05-09T04:22:42Z                                     ║
# ║  This script is retained as a fallback reference only.                 ║
# ║  The canonical provisioning path is now AZD + Bicep:                   ║
# ║                                                                         ║
# ║    azd provision   →  infra/main.bicep (Bicep templates)               ║
# ║    azd deploy      →  deploys server/ FastMCP code                     ║
# ║                                                                         ║
# ║  See infra/README.md for full AZD setup instructions.                  ║
# ║  Run this script only if AZD + Bicep is unavailable or you need a      ║
# ║  quick CLI-only path for a specific env without AZD.                   ║
# ╚══════════════════════════════════════════════════════════════════════════╝
#
# Provisions two Entra app registrations (repro + fixed) and a new FastMCP
# App Service with production and staging slots for side-by-side demonstration
# of the H1 OAuth redirect-URI bug.
#
# Slot assignment (LOCKED — decisions.md D9 / Piotr directive 2026-05-09):
#   production  →  cloud-helper-mcp-repro   (H1 bug preserved, http://localhost only)
#   staging     →  cloud-helper-mcp-fixed   (H1 corrected, adds http://127.0.0.1)
#
# The new App Service (cloud-helper-fastmcp) reuses the existing App Service Plan
# from cloud-helper-mcp but is otherwise a clean slate — no inherited IP restrictions.
#
# CLIENT_ID, AUDIENCE, RESOURCE_HOST, AZURE_CLIENT_ID, and AZURE_TENANT_ID are
# marked sticky so a slot swap never silently changes which app reg is in use.
#
# Usage:
#   ./scripts/provision-two-app-regs.sh [--dry-run] [-h|--help]
#
# Options:
#   --dry-run   Print write commands without executing them (reads still run)
#   -h, --help  Show this help message
#
# Prerequisites:
#   az CLI, jq, python3 — all on PATH
#   Logged in to the tenant that owns TARGET_SUB: az login --tenant <TENANT_ID>
#   Application Administrator or higher on the Entra tenant
#
# See scripts/README.md for full documentation.

set -euo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION — edit these two required values before running
# ══════════════════════════════════════════════════════════════════════════════

# Entra tenant GUID.  Find with: az account show --query tenantId --output tsv
TENANT_ID=""

# Azure subscription name or ID that hosts the App Service.
# Example: "Cloud Brokers - ASC Testing"
TARGET_SUB=""

# ── Optional overrides (defaults are correct for this project) ─────────────────
TARGET_RG="${TARGET_RG:-rg-cloud-helper-mcp}"
EXISTING_APP="${EXISTING_APP:-cloud-helper-mcp}"
NEW_APP="${NEW_APP:-cloud-helper-fastmcp}"
SLOT="${SLOT:-staging}"

# ══════════════════════════════════════════════════════════════════════════════
# END CONFIGURATION
# ══════════════════════════════════════════════════════════════════════════════

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}ℹ${RESET}  $*"; }
success() { echo -e "${GREEN}✅${RESET} $*"; }
warn()    { echo -e "${YELLOW}⚠️ ${RESET} $*"; }
error()   { echo -e "${RED}❌${RESET} $*" >&2; }
header()  { echo -e "\n${BOLD}${CYAN}── $* ──${RESET}"; }
dryrun()  { echo -e "${YELLOW}[DRY-RUN]${RESET} $*"; }
die()     { error "$*"; exit 1; }

# ── Arg parsing ────────────────────────────────────────────────────────────────
DRY_RUN=false

usage() {
  grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -30
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage ;;
    *) die "Unknown flag: $1  (run '$0 --help' for usage)" ;;
  esac
done

if [[ "$DRY_RUN" == "true" ]]; then
  echo -e "\n${YELLOW}⚠️  DRY-RUN mode — write operations printed, not executed${RESET}\n"
fi

# ── run: execute or print in dry-run mode ─────────────────────────────────────
# Usage: run az webapp create ...
# Reads (az ... show/list) should be called directly, not via run.
run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    dryrun "$*"
  else
    "$@"
  fi
}

# ── Config validation ──────────────────────────────────────────────────────────
[[ -z "$TENANT_ID"  ]] && die "TENANT_ID is empty. Fill in the CONFIGURATION block at the top of this script."
[[ -z "$TARGET_SUB" ]] && die "TARGET_SUB is empty. Fill in the CONFIGURATION block at the top of this script."

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1 — RS-mode API helper function
#
# configure_rs_api <app_obj_id> <client_id>
#
# Configures an Entra app registration as an OAuth2 Resource Server:
#   • Application ID URI  →  api://<client_id>
#   • Scope               →  mcp.access  (delegated, User consent)
#   • Token version       →  2  (required for Bearer JWT validation)
#   • Service principal   →  created if absent
#
# Idempotent: reuses the existing mcp.access scope GUID if already present.
# ══════════════════════════════════════════════════════════════════════════════
configure_rs_api() {
  local app_obj_id="$1"
  local client_id="$2"

  info "Configuring RS-mode API: identifier_uri=api://$client_id  scope=mcp.access  token_v=2"

  # Preserve existing scope GUID so re-runs don't create a new random ID
  local existing_scope_id=""
  if [[ "$DRY_RUN" == "false" && "$app_obj_id" != *placeholder* ]]; then
    existing_scope_id="$(az ad app show --id "$app_obj_id" \
      --query "api.oauth2PermissionScopes[?value=='mcp.access'].id | [0]" \
      --output tsv 2>/dev/null || true)"
  fi

  local scope_id
  if [[ -n "$existing_scope_id" ]]; then
    scope_id="$existing_scope_id"
    info "Reusing existing mcp.access scope id: $scope_id"
  else
    scope_id="$(python3 -c 'import uuid; print(uuid.uuid4())')"
    info "Generated new scope id: $scope_id"
  fi

  # Build the scope JSON using an env var to safely pass the UUID into Python
  local scope_json
  scope_json="$(SCOPE_ID="$scope_id" python3 - <<'PYEOF'
import json, os
print(json.dumps([{
  "id":                       os.environ["SCOPE_ID"],
  "adminConsentDisplayName":  "Access FastMCP server",
  "adminConsentDescription":  "Allows the app to access the FastMCP server on behalf of the signed-in user",
  "userConsentDisplayName":   "Access FastMCP server",
  "isEnabled":                True,
  "type":                     "User",
  "value":                    "mcp.access"
}], separators=(",", ":")))
PYEOF
)"

  # Set Application ID URI (separate call — avoids --set / --identifier-uris flag conflict)
  run az ad app update --id "$app_obj_id" \
    --identifier-uris "api://$client_id"

  # Set token version v2 and the mcp.access scope
  run az ad app update --id "$app_obj_id" \
    --set "api.requestedAccessTokenVersion=2"

  run az ad app update --id "$app_obj_id" \
    --set "api.oauth2PermissionScopes=$scope_json"

  # Ensure service principal exists (needed for token issuance)
  if [[ "$DRY_RUN" == "true" ]]; then
    dryrun "az ad sp create --id $client_id --only-show-errors"
  else
    az ad sp create --id "$client_id" --only-show-errors >/dev/null 2>&1 || true
    success "Service principal ensured for client_id=$client_id"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 0 — Preflight: az login check, subscription set, resource group verify
# ══════════════════════════════════════════════════════════════════════════════
header "Step 0 — Preflight"

command -v az  &>/dev/null || die "az CLI not found. Install: https://docs.microsoft.com/cli/azure/install-azure-cli"
command -v jq  &>/dev/null || die "jq not found. Install: https://stedolan.github.io/jq/"
command -v python3 &>/dev/null || die "python3 not found."

AZ_VERSION="$(az version --query '"azure-cli"' --output tsv 2>/dev/null || echo 'unknown')"
success "az CLI found: $AZ_VERSION"

az account show &>/dev/null || die "Not logged in. Run: az login --tenant $TENANT_ID"
CURRENT_USER="$(az account show --query user.name --output tsv)"
success "Logged in as: $CURRENT_USER"

info "Setting subscription: $TARGET_SUB"
run az account set --subscription "$TARGET_SUB"

if [[ "$DRY_RUN" == "false" ]]; then
  ACTIVE_SUB="$(az account show --query name --output tsv)"
  success "Active subscription: $ACTIVE_SUB"

  info "Verifying resource group: $TARGET_RG"
  az group show --name "$TARGET_RG" --output none \
    || die "Resource group '$TARGET_RG' not found in subscription '$ACTIVE_SUB'."
  success "Resource group exists: $TARGET_RG"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2 — Create (or verify) repro app registration: cloud-helper-mcp-repro
#
# Slot mapping:  production  →  REPRO  (H1 bug preserved for demonstration)
#
# Public client redirect URIs:  http://localhost  ONLY — no 127.0.0.1
# Web redirect URIs:            https://foundry.azure.com/  https://vscode.dev/redirect
# ══════════════════════════════════════════════════════════════════════════════
header "Step 2 — Repro app registration (cloud-helper-mcp-repro)"

REPRO_APP_NAME="cloud-helper-mcp-repro"

info "Checking for existing app registration: $REPRO_APP_NAME"
REPRO_JSON="$(az ad app list \
  --filter "displayName eq '$REPRO_APP_NAME'" \
  --query '[0].{objId:id,clientId:appId}' \
  --output json 2>/dev/null || echo 'null')"

REPRO_APP_OBJ_ID="$(echo "$REPRO_JSON" | jq -r '.objId // empty' 2>/dev/null || true)"

if [[ -z "$REPRO_APP_OBJ_ID" ]]; then
  info "$REPRO_APP_NAME not found — creating"
  if [[ "$DRY_RUN" == "true" ]]; then
    dryrun "az ad app create --display-name $REPRO_APP_NAME \
--sign-in-audience AzureADMyOrg --is-fallback-public-client true \
--public-client-redirect-uris http://localhost \
--web-redirect-uris https://foundry.azure.com/ https://vscode.dev/redirect"
    REPRO_APP_OBJ_ID="<repro-obj-id-placeholder>"
    REPRO_CLIENT_ID="<repro-client-id-placeholder>"
  else
    REPRO_JSON="$(az ad app create \
      --display-name "$REPRO_APP_NAME" \
      --sign-in-audience AzureADMyOrg \
      --is-fallback-public-client true \
      --public-client-redirect-uris "http://localhost" \
      --web-redirect-uris "https://foundry.azure.com/" "https://vscode.dev/redirect" \
      --query '{objId:id,clientId:appId}' \
      --output json)"
    REPRO_APP_OBJ_ID="$(echo "$REPRO_JSON" | jq -r '.objId')"
    REPRO_CLIENT_ID="$(echo "$REPRO_JSON" | jq -r '.clientId')"
    success "Created $REPRO_APP_NAME — client_id=$REPRO_CLIENT_ID"
  fi
else
  REPRO_CLIENT_ID="$(echo "$REPRO_JSON" | jq -r '.clientId')"
  success "Found existing $REPRO_APP_NAME — client_id=$REPRO_CLIENT_ID"
  # Idempotent: enforce canonical repro redirect URI state
  info "Enforcing canonical redirect URIs for repro (http://localhost only)"
  run az ad app update --id "$REPRO_APP_OBJ_ID" \
    --is-fallback-public-client true \
    --public-client-redirect-uris "http://localhost" \
    --web-redirect-uris "https://foundry.azure.com/" "https://vscode.dev/redirect"
fi

configure_rs_api "$REPRO_APP_OBJ_ID" "$REPRO_CLIENT_ID"
success "Repro app registration ready — client_id=$REPRO_CLIENT_ID"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3 — Create (or verify) fixed app registration: cloud-helper-mcp-fixed
#
# Slot mapping:  staging  →  FIXED  (H1 corrected)
#
# Public client redirect URIs:  http://localhost  AND  http://127.0.0.1
# Web redirect URIs:            https://foundry.azure.com/  https://vscode.dev/redirect
# ══════════════════════════════════════════════════════════════════════════════
header "Step 3 — Fixed app registration (cloud-helper-mcp-fixed)"

FIXED_APP_NAME="cloud-helper-mcp-fixed"

info "Checking for existing app registration: $FIXED_APP_NAME"
FIXED_JSON="$(az ad app list \
  --filter "displayName eq '$FIXED_APP_NAME'" \
  --query '[0].{objId:id,clientId:appId}' \
  --output json 2>/dev/null || echo 'null')"

FIXED_APP_OBJ_ID="$(echo "$FIXED_JSON" | jq -r '.objId // empty' 2>/dev/null || true)"

if [[ -z "$FIXED_APP_OBJ_ID" ]]; then
  info "$FIXED_APP_NAME not found — creating"
  if [[ "$DRY_RUN" == "true" ]]; then
    dryrun "az ad app create --display-name $FIXED_APP_NAME \
--sign-in-audience AzureADMyOrg --is-fallback-public-client true \
--public-client-redirect-uris http://localhost http://127.0.0.1 \
--web-redirect-uris https://foundry.azure.com/ https://vscode.dev/redirect"
    FIXED_APP_OBJ_ID="<fixed-obj-id-placeholder>"
    FIXED_CLIENT_ID="<fixed-client-id-placeholder>"
  else
    FIXED_JSON="$(az ad app create \
      --display-name "$FIXED_APP_NAME" \
      --sign-in-audience AzureADMyOrg \
      --is-fallback-public-client true \
      --public-client-redirect-uris "http://localhost" "http://127.0.0.1" \
      --web-redirect-uris "https://foundry.azure.com/" "https://vscode.dev/redirect" \
      --query '{objId:id,clientId:appId}' \
      --output json)"
    FIXED_APP_OBJ_ID="$(echo "$FIXED_JSON" | jq -r '.objId')"
    FIXED_CLIENT_ID="$(echo "$FIXED_JSON" | jq -r '.clientId')"
    success "Created $FIXED_APP_NAME — client_id=$FIXED_CLIENT_ID"
  fi
else
  FIXED_CLIENT_ID="$(echo "$FIXED_JSON" | jq -r '.clientId')"
  success "Found existing $FIXED_APP_NAME — client_id=$FIXED_CLIENT_ID"
  # Idempotent: enforce canonical fixed redirect URI state
  info "Enforcing canonical redirect URIs for fixed (http://localhost + http://127.0.0.1)"
  run az ad app update --id "$FIXED_APP_OBJ_ID" \
    --is-fallback-public-client true \
    --public-client-redirect-uris "http://localhost" "http://127.0.0.1" \
    --web-redirect-uris "https://foundry.azure.com/" "https://vscode.dev/redirect"
fi

configure_rs_api "$FIXED_APP_OBJ_ID" "$FIXED_CLIENT_ID"
success "Fixed app registration ready — client_id=$FIXED_CLIENT_ID"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4 — Read-only inspect of existing legacy app (cloud-helper-mcp)
#
# Shows current slots and access restrictions — no changes made.
# If access restrictions show explicit allow rules / default deny, that explains
# the 403 Ip Forbidden seen from external IPs (separate from the OAuth bug).
# ══════════════════════════════════════════════════════════════════════════════
header "Step 4 — Inspect legacy app (read-only: $EXISTING_APP)"

info "Deployment slots on $EXISTING_APP:"
az webapp deployment slot list \
  --resource-group "$TARGET_RG" \
  --name "$EXISTING_APP" \
  --output table 2>/dev/null \
  || warn "Could not list slots for $EXISTING_APP (subscription access?)"

info "Access restrictions on $EXISTING_APP:"
az webapp config access-restriction show \
  --resource-group "$TARGET_RG" \
  --name "$EXISTING_APP" \
  --output yaml 2>/dev/null \
  || warn "Could not read access restrictions for $EXISTING_APP"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5 — Create new App Service (cloud-helper-fastmcp) and staging slot
#
# Reuses the existing App Service Plan from cloud-helper-mcp.
# No IP allowlisting applied — clean slate for repro/fixed testing.
# ══════════════════════════════════════════════════════════════════════════════
header "Step 5 — New App Service ($NEW_APP) + staging slot ($SLOT)"

# 5a. Resolve App Service Plan name from the existing legacy app
info "Looking up App Service Plan from $EXISTING_APP"
if [[ "$DRY_RUN" == "false" ]]; then
  APP_SERVICE_PLAN_ID="$(az webapp show \
    --resource-group "$TARGET_RG" \
    --name "$EXISTING_APP" \
    --query serverFarmId \
    --output tsv)"
  APP_SERVICE_PLAN_NAME="$(basename "$APP_SERVICE_PLAN_ID")"
  success "App Service Plan: $APP_SERVICE_PLAN_NAME"
else
  APP_SERVICE_PLAN_NAME="<plan-name-from-$EXISTING_APP>"
  dryrun "az webapp show --resource-group $TARGET_RG --name $EXISTING_APP --query serverFarmId --output tsv"
  info "Plan name will be derived from the above command at runtime"
fi

# 5b. Create new App Service (idempotent)
info "Checking if $NEW_APP exists"
if az webapp show --resource-group "$TARGET_RG" --name "$NEW_APP" --output none 2>/dev/null; then
  success "$NEW_APP already exists — skipping creation"
else
  info "$NEW_APP not found — creating"
  run az webapp create \
    --resource-group "$TARGET_RG" \
    --plan "$APP_SERVICE_PLAN_NAME" \
    --name "$NEW_APP" \
    --runtime "PYTHON:3.12"
  success "App Service created: $NEW_APP"
fi

# 5c. Create staging slot (idempotent)
info "Checking if slot '$SLOT' exists on $NEW_APP"
if az webapp deployment slot show \
     --resource-group "$TARGET_RG" \
     --name "$NEW_APP" \
     --slot "$SLOT" \
     --output none 2>/dev/null; then
  success "Slot '$SLOT' already exists on $NEW_APP — skipping creation"
else
  info "Slot '$SLOT' not found — creating"
  run az webapp deployment slot create \
    --resource-group "$TARGET_RG" \
    --name "$NEW_APP" \
    --slot "$SLOT" \
    --configuration-source "$NEW_APP"
  success "Created slot '$SLOT' on $NEW_APP"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6 — Shared app settings (non-sticky, same on both slots)
#
# These travel with slot swaps and are safe to share:
#   TENANT_ID                      — Entra tenant for JWT validation
#   PORT=8000                      — FastMCP server listen port
#   SCM_DO_BUILD_DURING_DEPLOYMENT — run pip install on Kudu deploy
# ══════════════════════════════════════════════════════════════════════════════
header "Step 6 — Shared app settings (TENANT_ID, PORT, SCM_DO_BUILD_DURING_DEPLOYMENT)"

info "Setting shared settings on production slot"
run az webapp config appsettings set \
  --resource-group "$TARGET_RG" \
  --name "$NEW_APP" \
  --settings \
    TENANT_ID="$TENANT_ID" \
    PORT=8000 \
    SCM_DO_BUILD_DURING_DEPLOYMENT=true

info "Setting shared settings on $SLOT slot"
run az webapp config appsettings set \
  --resource-group "$TARGET_RG" \
  --name "$NEW_APP" \
  --slot "$SLOT" \
  --settings \
    TENANT_ID="$TENANT_ID" \
    PORT=8000 \
    SCM_DO_BUILD_DURING_DEPLOYMENT=true

success "Shared settings applied to both slots"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 7 — Sticky slot settings (per-slot, survive slot swaps)
#
# These are marked sticky so that a slot swap NEVER silently changes which
# app registration is in use.  To flip production, update settings explicitly
# (see Step 9) — do not rely on slot swap alone.
#
# Production slot  →  REPRO  (H1 bug preserved)
#   CLIENT_ID        = $REPRO_CLIENT_ID
#   AUDIENCE         = api://$REPRO_CLIENT_ID
#   RESOURCE_HOST    = $NEW_APP.azurewebsites.net
#   AZURE_CLIENT_ID  = $REPRO_CLIENT_ID   (compat with legacy env var name)
#   AZURE_TENANT_ID  = $TENANT_ID
#
# Staging slot ($SLOT)  →  FIXED  (H1 corrected)
#   CLIENT_ID        = $FIXED_CLIENT_ID
#   AUDIENCE         = api://$FIXED_CLIENT_ID
#   RESOURCE_HOST    = $NEW_APP-$SLOT.azurewebsites.net
#   AZURE_CLIENT_ID  = $FIXED_CLIENT_ID
#   AZURE_TENANT_ID  = $TENANT_ID
# ══════════════════════════════════════════════════════════════════════════════
header "Step 7 — Sticky slot settings (auth profile per slot)"

info "Production slot ← REPRO (client_id=$REPRO_CLIENT_ID)"
run az webapp config appsettings set \
  --resource-group "$TARGET_RG" \
  --name "$NEW_APP" \
  --slot-settings \
    CLIENT_ID="$REPRO_CLIENT_ID" \
    AUDIENCE="api://$REPRO_CLIENT_ID" \
    RESOURCE_HOST="$NEW_APP.azurewebsites.net" \
    AZURE_CLIENT_ID="$REPRO_CLIENT_ID" \
    AZURE_TENANT_ID="$TENANT_ID"

info "Staging slot ($SLOT) ← FIXED (client_id=$FIXED_CLIENT_ID)"
run az webapp config appsettings set \
  --resource-group "$TARGET_RG" \
  --name "$NEW_APP" \
  --slot "$SLOT" \
  --slot-settings \
    CLIENT_ID="$FIXED_CLIENT_ID" \
    AUDIENCE="api://$FIXED_CLIENT_ID" \
    RESOURCE_HOST="$NEW_APP-$SLOT.azurewebsites.net" \
    AZURE_CLIENT_ID="$FIXED_CLIENT_ID" \
    AZURE_TENANT_ID="$TENANT_ID"

success "Sticky slot settings applied"
warn "Slot swap does NOT change the auth profile (sticky settings are per-slot)."
info "To flip production to the fixed app reg, use the appsettings update in Step 9."

# ══════════════════════════════════════════════════════════════════════════════
# STEP 8 — Validation
#
# Shows app reg redirect URIs / scopes and slot appsettings for the key vars.
# ══════════════════════════════════════════════════════════════════════════════
header "Step 8 — Validation"

if [[ "$DRY_RUN" == "true" ]]; then
  warn "Skipping validation reads in dry-run mode (no real resources exist yet)"
else
  info "--- Repro app registration ($REPRO_APP_NAME) ---"
  az ad app show --id "$REPRO_APP_OBJ_ID" \
    --query '{displayName:displayName,publicClientUris:publicClient.redirectUris,webUris:web.redirectUris,identifierUris:identifierUris,scopes:api.oauth2PermissionScopes[].value,tokenVersion:api.requestedAccessTokenVersion}' \
    --output yaml 2>/dev/null \
    || warn "Could not read repro app registration"

  info "--- Fixed app registration ($FIXED_APP_NAME) ---"
  az ad app show --id "$FIXED_APP_OBJ_ID" \
    --query '{displayName:displayName,publicClientUris:publicClient.redirectUris,webUris:web.redirectUris,identifierUris:identifierUris,scopes:api.oauth2PermissionScopes[].value,tokenVersion:api.requestedAccessTokenVersion}' \
    --output yaml 2>/dev/null \
    || warn "Could not read fixed app registration"

  info "--- Production slot appsettings ---"
  az webapp config appsettings list \
    --resource-group "$TARGET_RG" \
    --name "$NEW_APP" \
    --query "[?name=='CLIENT_ID' || name=='AUDIENCE' || name=='RESOURCE_HOST' || name=='AZURE_CLIENT_ID' || name=='AZURE_TENANT_ID'].{name:name,slotSetting:slotSetting,value:value}" \
    --output table 2>/dev/null \
    || warn "Could not read production slot appsettings"

  info "--- Staging slot ($SLOT) appsettings ---"
  az webapp config appsettings list \
    --resource-group "$TARGET_RG" \
    --name "$NEW_APP" \
    --slot "$SLOT" \
    --query "[?name=='CLIENT_ID' || name=='AUDIENCE' || name=='RESOURCE_HOST' || name=='AZURE_CLIENT_ID' || name=='AZURE_TENANT_ID'].{name:name,slotSetting:slotSetting,value:value}" \
    --output table 2>/dev/null \
    || warn "Could not read staging slot appsettings"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 9 — Cutover command (COMMENTED OUT BY DEFAULT)
#
# When Piotr confirms the fix is working on staging, run this block to make
# production point to the FIXED app registration.
#
# This does NOT do a slot swap — it updates the sticky slot settings in-place
# so the production slot switches auth profile without moving code.
# For a code + auth cutover, also uncomment the slot swap below.
# ══════════════════════════════════════════════════════════════════════════════
header "Step 9 — Cutover to fixed (COMMENTED OUT — uncomment when ready)"

cat <<'CUTOVER'

# ── Uncomment to cut production over to the FIXED app registration ────────────
#
# az webapp config appsettings set \
#   --resource-group "$TARGET_RG" \
#   --name "$NEW_APP" \
#   --slot-settings \
#     CLIENT_ID="$FIXED_CLIENT_ID" \
#     AUDIENCE="api://$FIXED_CLIENT_ID" \
#     RESOURCE_HOST="$NEW_APP.azurewebsites.net" \
#     AZURE_CLIENT_ID="$FIXED_CLIENT_ID" \
#     AZURE_TENANT_ID="$TENANT_ID"
#
# ── Optional: also swap code from staging to production ───────────────────────
#
# az webapp deployment slot swap \
#   --resource-group "$TARGET_RG" \
#   --name "$NEW_APP" \
#   --slot "$SLOT" \
#   --target-slot production

CUTOVER

# ══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}${GREEN}=== Provisioning complete ===${RESET}"
echo ""
echo "Repro app reg: $REPRO_CLIENT_ID  → production slot (broken — H1 preserved)"
echo "Fixed app reg: $FIXED_CLIENT_ID  → staging slot    (fixed — H1 corrected)"
echo ""
echo "Test sequence:"
echo "  1. Deploy server: cd server && az webapp deployment ... (TBD after server is packaged)"
echo "  2. Run repro test: python client/test_oauth_client.py --server https://$NEW_APP.azurewebsites.net"
echo "  3. Run fix test:   python client/test_oauth_client.py --server https://$NEW_APP-$SLOT.azurewebsites.net"
echo "  4. To cut over production to fixed: uncomment and run Step 9"
echo ""
