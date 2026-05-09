#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CLIENT_ENV_FILE="$ROOT_DIR/client/.env"

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

require_var AZURE_TENANT_ID
require_var REPRO_CLIENT_ID
require_var FIXED_CLIENT_ID
require_var WEB_APP_NAME
require_var AZURE_RESOURCE_GROUP

RESOURCE_GROUP_SUFFIX=${AZURE_RESOURCE_GROUP#rg-}
REPRO_SERVER_URL="https://${WEB_APP_NAME}.azurewebsites.net"
FIXED_SERVER_URL="https://${WEB_APP_NAME}-staging.azurewebsites.net"
REPRO_AUDIENCE="api://cloud-helper-mcp-repro-${RESOURCE_GROUP_SUFFIX}"
FIXED_AUDIENCE="api://cloud-helper-mcp-fixed-${RESOURCE_GROUP_SUFFIX}"

cat > "$CLIENT_ENV_FILE" <<EOF
TENANT_ID=$AZURE_TENANT_ID
REPRO_CLIENT_ID=$REPRO_CLIENT_ID
FIXED_CLIENT_ID=$FIXED_CLIENT_ID
WEB_APP_NAME=$WEB_APP_NAME
REPRO_SERVER_URL=$REPRO_SERVER_URL
FIXED_SERVER_URL=$FIXED_SERVER_URL
REPRO_AUDIENCE=$REPRO_AUDIENCE
FIXED_AUDIENCE=$FIXED_AUDIENCE
EOF

echo "Wrote $CLIENT_ENV_FILE"
sed -n '1,999p' "$CLIENT_ENV_FILE"
