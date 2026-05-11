#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CLIENT_ENV_FILE="$ROOT_DIR/client/.env"
VSCODE_MCP_FILE="$ROOT_DIR/.vscode/mcp.json"

AZD_ENV_VALUES=$(azd env get-values)
if [ -z "$AZD_ENV_VALUES" ]; then
  echo "ERROR: 'azd env get-values' returned no values." >&2
  exit 1
fi

eval "$AZD_ENV_VALUES"

require_var() {
  var_name="$1"
  eval "var_value=\${$var_name-}"
  if [ -z "$var_value" ]; then
    echo "ERROR: Required AZD environment value '$var_name' is missing." >&2
    exit 1
  fi
}

ensure_sp() {
  app_id="$1"
  label="$2"
  sp_id=$(az ad sp list --filter "appId eq '$app_id'" --query "[0].id" -o tsv 2>/dev/null)
  if [ -z "$sp_id" ]; then
    sp_id=$(az ad sp create --id "$app_id" --query id -o tsv)
    echo "postprovision: Created $label service principal $sp_id."
  else
    echo "postprovision: $label service principal already exists ($sp_id)."
  fi
}

require_var AZURE_TENANT_ID
require_var REPRO_CLIENT_ID
require_var FIXED_CLIENT_ID
require_var REPRO_AUDIENCE
require_var FIXED_AUDIENCE
require_var WEB_APP_NAME

echo "postprovision: Ensuring service principals exist for direct-Entra app registrations..."
ensure_sp "$REPRO_CLIENT_ID" "repro"
ensure_sp "$FIXED_CLIENT_ID" "fixed"

REPRO_SERVER_URL="https://${WEB_APP_NAME}.azurewebsites.net/mcp"
FIXED_SERVER_URL="https://${WEB_APP_NAME}-staging.azurewebsites.net/mcp"

cat > "$CLIENT_ENV_FILE" <<EOF_CLIENT_ENV
TENANT_ID=$AZURE_TENANT_ID
REPRO_CLIENT_ID=$REPRO_CLIENT_ID
FIXED_CLIENT_ID=$FIXED_CLIENT_ID
WEB_APP_NAME=$WEB_APP_NAME
REPRO_SERVER_URL=$REPRO_SERVER_URL
FIXED_SERVER_URL=$FIXED_SERVER_URL
REPRO_AUDIENCE=$REPRO_AUDIENCE
FIXED_AUDIENCE=$FIXED_AUDIENCE
EOF_CLIENT_ENV

echo "Wrote $CLIENT_ENV_FILE"
sed -n '1,999p' "$CLIENT_ENV_FILE"

mkdir -p "$ROOT_DIR/.vscode"
cat > "$VSCODE_MCP_FILE" <<EOF_VSCODE
{
  "servers": {
    "cloud-helper-fixed": {
      "type": "http",
      "url": "$FIXED_SERVER_URL"
    }
  }
}
EOF_VSCODE
echo "Wrote $VSCODE_MCP_FILE"
