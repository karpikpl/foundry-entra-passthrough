#!/usr/bin/env bash
# fix-entra-redirect-uri.sh
#
# Adds http://127.0.0.1 as a public-client (Mobile/Desktop) redirect URI to an
# Entra app registration, alongside the existing http://localhost entry.
#
# Background: RFC 8252 §8.3 — localhost and 127.0.0.1 are distinct loopback
# identifiers. Entra does NOT treat them interchangeably. MCP clients bind their
# callback listener to 127.0.0.1, so both URIs must be registered.
#
# Usage:
#   ./fix-entra-redirect-uri.sh [OPTIONS]
#
# Options:
#   --tenant-id       <id>    Entra tenant ID (GUID or domain)
#   --subscription    <name>  Azure subscription name or ID
#   --app-id          <id>    App registration object ID (preferred)
#   --app-name        <name>  App registration display name (used if --app-id not given)
#   --dry-run                 Show what would be done; make no changes
#   -h, --help                Show this help message

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
DEFAULT_APP_NAME="cloud-helper-mcp"
TARGET_URI="http://127.0.0.1"

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
APP_ID=""
APP_NAME=""
DRY_RUN=false

usage() {
  grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -25
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant-id)    TENANT_ID="$2";    shift 2 ;;
    --subscription) SUBSCRIPTION="$2"; shift 2 ;;
    --app-id)       APP_ID="$2";       shift 2 ;;
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
header "Locating app registration"

if [[ -z "$APP_ID" ]]; then
  LOOKUP_NAME="${APP_NAME:-$DEFAULT_APP_NAME}"
  info "Looking up app by display name: '${LOOKUP_NAME}'"
  APP_ID=$(az ad app list \
    --filter "displayName eq '${LOOKUP_NAME}'" \
    --query "[0].id" \
    -o tsv 2>/dev/null)

  if [[ -z "$APP_ID" ]]; then
    error "No app registration found with display name '${LOOKUP_NAME}' in tenant ${TENANT_ID}."
    echo "  Use --app-id <objectId> or --app-name <exactDisplayName> to specify the app."
    exit 1
  fi
  success "Found app '${LOOKUP_NAME}' → Object ID: ${APP_ID}"
else
  # Validate provided app ID exists
  DISPLAY_NAME=$(az ad app show --id "$APP_ID" --query "displayName" -o tsv 2>/dev/null)
  if [[ -z "$DISPLAY_NAME" ]]; then
    error "No app registration found with object ID '${APP_ID}'."
    exit 1
  fi
  success "Found app '${DISPLAY_NAME}' (${APP_ID})"
fi

# ── Current state ──────────────────────────────────────────────────────────────
header "Current redirect URI state"

# publicClient.redirectUris holds the Mobile/Desktop URIs
CURRENT_URIS_JSON=$(az ad app show --id "$APP_ID" \
  --query "publicClient.redirectUris" -o json 2>/dev/null)

echo "  Public-client redirect URIs:"
if [[ "$CURRENT_URIS_JSON" == "null" || "$CURRENT_URIS_JSON" == "[]" ]]; then
  warn "  (none registered)"
  CURRENT_URIS=()
else
  mapfile -t CURRENT_URIS < <(echo "$CURRENT_URIS_JSON" | tr -d '[]"' | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$')
  for uri in "${CURRENT_URIS[@]}"; do
    echo "    • ${uri}"
  done
fi

# ── Idempotency check ──────────────────────────────────────────────────────────
header "Idempotency check"

if printf '%s\n' "${CURRENT_URIS[@]}" | grep -qxF "$TARGET_URI"; then
  success "${TARGET_URI} is already registered. Nothing to do."
  exit 0
fi

info "${TARGET_URI} is NOT currently registered — will add it."

# ── Build new URI list ─────────────────────────────────────────────────────────
# Merge existing URIs + new target URI (deduped)
declare -A URI_SET
for uri in "${CURRENT_URIS[@]}"; do
  [[ -n "$uri" ]] && URI_SET["$uri"]=1
done
URI_SET["$TARGET_URI"]=1

NEW_URIS=("${!URI_SET[@]}")
# Sort for deterministic output
IFS=$'\n' NEW_URIS_SORTED=($(sort <<<"${NEW_URIS[*]}")); unset IFS

echo ""
info "New public-client redirect URIs will be:"
for uri in "${NEW_URIS_SORTED[@]}"; do
  echo "    • ${uri}"
done

# ── Apply the change ───────────────────────────────────────────────────────────
header "Applying change"

CMD="az ad app update --id \"${APP_ID}\" --public-client-redirect-uris ${NEW_URIS_SORTED[*]}"

if $DRY_RUN; then
  dryrun "Would run:"
  dryrun "  ${CMD}"
  echo ""
  warn "Dry-run mode — no changes made."
  exit 0
fi

info "Running: ${CMD}"
az ad app update --id "$APP_ID" --public-client-redirect-uris "${NEW_URIS_SORTED[@]}"
success "az ad app update completed."

# ── Verify ─────────────────────────────────────────────────────────────────────
header "Verification"

info "Re-reading app registration to confirm change..."
sleep 2  # brief pause — Entra Graph replication can lag by ~1s

VERIFIED_JSON=$(az ad app show --id "$APP_ID" \
  --query "publicClient.redirectUris" -o json 2>/dev/null)

echo "  Registered public-client redirect URIs (after update):"
if [[ "$VERIFIED_JSON" == "null" || "$VERIFIED_JSON" == "[]" ]]; then
  error "No URIs found after update — something went wrong."
  exit 1
fi

mapfile -t VERIFIED_URIS < <(echo "$VERIFIED_JSON" | tr -d '[]"' | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$')
for uri in "${VERIFIED_URIS[@]}"; do
  echo "    • ${uri}"
done

if printf '%s\n' "${VERIFIED_URIS[@]}" | grep -qxF "$TARGET_URI"; then
  success "${TARGET_URI} confirmed present in app registration."
else
  error "${TARGET_URI} NOT found after update. Manual investigation required."
  exit 1
fi

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
success "Done. Entra app registration is now RFC 8252 §8.3-compliant for loopback clients."
echo ""
echo "  Next steps:"
echo "    1. Re-test OAuth PKCE flow with client/test_oauth_client.py"
echo "    2. Verify /.well-known/oauth-authorization-server advertises both loopback URIs"
echo "    3. Confirm CORS on cloud-helper-mcp allows Foundry/VS Code origins"
echo ""
