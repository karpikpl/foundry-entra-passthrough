#!/usr/bin/env bash
# setup-entra-rs-mode.sh
#
# Sets up Entra ID app registration for an MCP server in RS-mode (Resource Server).
#
# RS-mode means the MCP server acts as an API (resource server), not an OAuth authorization
# server. Clients (VS Code, AI Foundry, etc.) obtain Bearer tokens directly from Entra ID,
# then POST those tokens to the MCP server. The server validates tokens via JWT inspection.
#
# This script:
#   1. Creates or reuses an Entra app registration (display name as app ID)
#   2. Sets Application ID URI: api://{client_id}
#   3. Defines an OAuth2 delegated permission scope: mcp.access
#   4. Sets accessTokenAcceptedVersion to 2 (required for v2 tokens)
#
# Reference: RFC 9728 (PRM) — Protected Resource Model
#
# Usage:
#   ./setup-entra-rs-mode.sh [OPTIONS]
#
# Options:
#   --tenant-id       <id>    Entra tenant ID (GUID or domain)
#   --subscription    <name>  Azure subscription name or ID
#   --app-name        <name>  App registration display name (default: cloud-helper-mcp)
#   --dry-run                 Show what would be done; make no changes
#   -h, --help                Show this help message

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
DEFAULT_APP_NAME="cloud-helper-mcp"
SCOPE_NAME="mcp.access"

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

# ── Arg parsing ────────────────────────────────────────────────────────────────
TENANT_ID=""
SUBSCRIPTION=""
APP_NAME=""
DRY_RUN=false

usage() {
  grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -30
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant-id)    TENANT_ID="$2";    shift 2 ;;
    --subscription) SUBSCRIPTION="$2"; shift 2 ;;
    --app-name)     APP_NAME="$2";     shift 2 ;;
    --dry-run)      DRY_RUN=true;      shift   ;;
    -h|--help)      usage ;;
    *) error "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Prereq: az CLI ─────────────────────────────────────────────────────────────
header "Checking prerequisites"

if ! command -v az &>/dev/null; then
  error "Azure CLI (az) is not installed or not on PATH."
  echo "  Install: https://docs.microsoft.com/cli/azure/install-azure-cli"
  exit 1
fi
success "az CLI found: $(az version --query '"azure-cli"' -o tsv 2>/dev/null || echo 'unknown version')"

# ── Prereq: logged in ──────────────────────────────────────────────────────────
if ! az account show &>/dev/null; then
  error "Not logged in to Azure CLI. Run: az login"
  exit 1
fi
CURRENT_USER=$(az account show --query "user.name" -o tsv 2>/dev/null)
success "Logged in as: ${CURRENT_USER}"

# ── Tenant selection ───────────────────────────────────────────────────────────
header "Tenant / subscription selection"

if [[ -n "$TENANT_ID" ]]; then
  info "Using tenant: ${TENANT_ID}"
elif [[ -n "$SUBSCRIPTION" ]]; then
  # Derive tenant from the subscription
  TENANT_ID=$(az account list \
    --query "[?name=='${SUBSCRIPTION}' || id=='${SUBSCRIPTION}'].tenantId | [0]" \
    -o tsv 2>/dev/null)
  if [[ -z "$TENANT_ID" ]]; then
    error "Could not resolve tenant for subscription '${SUBSCRIPTION}'."
    echo "  Run 'az account list' to see available subscriptions."
    exit 1
  fi
  info "Resolved tenant ${TENANT_ID} from subscription '${SUBSCRIPTION}'"
else
  TENANT_ID=$(az account show --query "tenantId" -o tsv 2>/dev/null)
  warn "No --tenant-id or --subscription provided. Using current tenant: ${TENANT_ID}"
fi

# ── Subscription selection ─────────────────────────────────────────────────────
if [[ -n "$SUBSCRIPTION" ]]; then
  info "Switching to subscription: ${SUBSCRIPTION}"
  if $DRY_RUN; then
    dryrun "az account set --subscription \"${SUBSCRIPTION}\""
  else
    az account set --subscription "$SUBSCRIPTION"
  fi
fi

ACTIVE_SUB=$(az account show --query "name" -o tsv 2>/dev/null)
info "Active subscription: ${ACTIVE_SUB}"

# ── App lookup ─────────────────────────────────────────────────────────────────
header "Locating or creating app registration"

LOOKUP_NAME="${APP_NAME:-$DEFAULT_APP_NAME}"
info "Checking for existing app: '${LOOKUP_NAME}'"

APP_ID=$(az ad app list \
  --filter "displayName eq '${LOOKUP_NAME}'" \
  --query "[0].id" \
  -o tsv 2>/dev/null)

if [[ -n "$APP_ID" ]]; then
  success "Found existing app '${LOOKUP_NAME}' → Object ID: ${APP_ID}"
  CREATED=false
else
  info "App '${LOOKUP_NAME}' does not exist. Creating..."
  
  if $DRY_RUN; then
    APP_ID="[DRY-RUN: generated-uuid-placeholder]"
    dryrun "Would create app: az ad app create --display-name \"${LOOKUP_NAME}\" --sign-in-audience AzureADMyOrg"
    dryrun "App ID would be: ${APP_ID}"
    CREATED=true
  else
    # Create app as confidential client (Resource Server, not public client)
    APP_ID=$(az ad app create \
      --display-name "$LOOKUP_NAME" \
      --sign-in-audience AzureADMyOrg \
      --query "id" -o tsv 2>/dev/null)
    
    if [[ -z "$APP_ID" ]]; then
      error "Failed to create app registration."
      exit 1
    fi
    success "Created app '${LOOKUP_NAME}' → Object ID: ${APP_ID}"
    CREATED=true
  fi
fi

# ── Application ID URI setup ───────────────────────────────────────────────────
header "Setting up Application ID URI"

if [[ "$DRY_RUN" == "true" ]]; then
  dryrun "az ad app update --id \"${APP_ID}\" --identifier-uris \"api://${APP_ID}\""
else
  # Check current identifier-uris
  CURRENT_ID_URI=$(az ad app show --id "$APP_ID" \
    --query "identifierUris[0]" -o tsv 2>/dev/null)
  
  if [[ "$CURRENT_ID_URI" == "api://${APP_ID}" ]]; then
    info "Application ID URI already set: api://${APP_ID}"
  else
    info "Setting Application ID URI to: api://${APP_ID}"
    az ad app update --id "$APP_ID" \
      --identifier-uris "api://${APP_ID}" >/dev/null 2>&1
    success "Application ID URI configured."
  fi
fi

# ── OAuth2 Scope setup ─────────────────────────────────────────────────────────
header "Configuring OAuth2 permission scope"

if [[ "$DRY_RUN" == "true" ]]; then
  SCOPE_ID="[DRY-RUN: generated-uuid-placeholder]"
  dryrun "Would add OAuth2 scope: ${SCOPE_NAME}"
  dryrun "  Scope ID: ${SCOPE_ID}"
else
  # Check if scope already exists
  SCOPE_EXISTS=$(az ad app show --id "$APP_ID" \
    --query "api.oauth2PermissionScopes[?value=='${SCOPE_NAME}'].id" \
    -o tsv 2>/dev/null)
  
  if [[ -n "$SCOPE_EXISTS" ]]; then
    info "Scope '${SCOPE_NAME}' already exists with ID: ${SCOPE_EXISTS}"
    SCOPE_ID="$SCOPE_EXISTS"
  else
    # Generate a new UUID for the scope
    SCOPE_ID=$(python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || uuidgen)
    
    info "Creating OAuth2 scope '${SCOPE_NAME}' with ID: ${SCOPE_ID}"
    
    # Build the scope definition as JSON
    SCOPE_DEF=$(cat <<EOF
[
  {
    "id": "${SCOPE_ID}",
    "adminConsentDisplayName": "Access MCP server",
    "adminConsentDescription": "Allows the app to access the MCP server on behalf of the signed-in user",
    "userConsentDisplayName": "Access MCP server",
    "value": "${SCOPE_NAME}",
    "type": "User",
    "isEnabled": true
  }
]
EOF
)
    
    # Add scope to app registration
    az ad app update --id "$APP_ID" \
      --set "api.oauth2PermissionScopes=$(echo "$SCOPE_DEF" | jq -c '.')" >/dev/null 2>&1
    
    success "OAuth2 scope '${SCOPE_NAME}' created."
  fi
fi

# ── Set accessTokenAcceptedVersion ────────────────────────────────────────────
header "Configuring token settings"

if [[ "$DRY_RUN" == "true" ]]; then
  dryrun "az ad app update --id \"${APP_ID}\" --set \"api.requestedAccessTokenVersion=2\""
else
  info "Setting accessTokenAcceptedVersion to 2 (v2 tokens)..."
  az ad app update --id "$APP_ID" \
    --set "api.requestedAccessTokenVersion=2" >/dev/null 2>&1
  success "Token version set to v2."
fi

# ── Summary output ─────────────────────────────────────────────────────────────
header "RS-mode setup complete"

echo ""
echo "  App Configuration:"
echo "    • Display Name:         ${LOOKUP_NAME}"
echo "    • App ID (client_id):   ${APP_ID}"
echo "    • Application ID URI:   api://${APP_ID}"
echo "    • OAuth2 Scope:         api://${APP_ID}/${SCOPE_NAME}"
echo "    • Token Version:        v2"
echo ""
echo "  Environment Variables (.env):"
echo "    export AZURE_CLIENT_ID=\"${APP_ID}\""
echo "    export AZURE_TENANT_ID=\"${TENANT_ID}\""
echo "    export MCP_RESOURCE_SCOPE=\"api://${APP_ID}/${SCOPE_NAME}\""
echo ""
echo "  Usage in Code:"
echo "    • Clients request tokens with scope: api://${APP_ID}/${SCOPE_NAME}"
echo "    • Tokens are Bearer tokens from Entra ID"
echo "    • Server validates tokens via JWT inspection (no token exchange)"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
  warn "Dry-run mode — no changes were made."
fi

if [[ "$CREATED" == "true" && "$DRY_RUN" == "false" ]]; then
  echo "  ✅ New app registration ready for Resource Server mode."
else
  echo "  ✅ App registration updated for Resource Server mode."
fi

echo ""
