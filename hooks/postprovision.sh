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

require_var AZURE_TENANT_ID
require_var REPRO_CLIENT_ID
require_var FIXED_CLIENT_ID
require_var PROXY_CLIENT_ID
require_var WEB_APP_NAME
require_var AZURE_RESOURCE_GROUP

# ── Client secret (first provision only) ──────────────────────────────────────
PROXY_CLIENT_SECRET_VAL=${PROXY_CLIENT_SECRET:-}

if [ -z "$PROXY_CLIENT_SECRET_VAL" ]; then
  echo "postprovision: First provision — creating client secret for proxy app ($PROXY_CLIENT_ID)..."
  PROXY_CLIENT_SECRET_VAL=$(az ad app credential reset \
    --id "$PROXY_CLIENT_ID" \
    --display-name "mcp-oauth-proxy" \
    --years 1 \
    --query password \
    --output tsv)

  azd env set PROXY_CLIENT_SECRET "$PROXY_CLIENT_SECRET_VAL"

  az webapp config appsettings set \
    --name "$WEB_APP_NAME" \
    --slot staging \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --settings "CLIENT_SECRET=$PROXY_CLIENT_SECRET_VAL" \
    --output none

  echo "postprovision: CLIENT_SECRET set on staging slot."
else
  echo "postprovision: PROXY_CLIENT_SECRET already set (re-provision) — skipping credential creation."
fi

# ── User consent grant: proxy → fixed mcp.access ─────────────────────────────
# The proxy app declares requiredResourceAccess pointing to the fixed app's
# mcp.access scope (type: User, no admin consent required). We still create an
# AllPrincipals oauth2PermissionGrant so users in the tenant don't each see a
# one-time consent prompt — it's a cleaner experience for a demo/corp deployment.
#
# This uses the proper client→resource model:
#   clientId  = proxy SP  (the app making the request)
#   resourceId = fixed SP  (the app owning the mcp.access scope)
echo "postprovision: Ensuring service principal exists for proxy app..."
PROXY_SP_ID=$(az ad sp list --filter "appId eq '$PROXY_CLIENT_ID'" --query "[0].id" -o tsv 2>/dev/null)
if [ -z "$PROXY_SP_ID" ]; then
  PROXY_SP_ID=$(az ad sp create --id "$PROXY_CLIENT_ID" --query id -o tsv)
  echo "postprovision: Created proxy SP $PROXY_SP_ID."
else
  echo "postprovision: Proxy SP already exists ($PROXY_SP_ID)."
fi

echo "postprovision: Ensuring service principal exists for fixed app..."
FIXED_SP_ID=$(az ad sp list --filter "appId eq '$FIXED_CLIENT_ID'" --query "[0].id" -o tsv 2>/dev/null)
if [ -z "$FIXED_SP_ID" ]; then
  FIXED_SP_ID=$(az ad sp create --id "$FIXED_CLIENT_ID" --query id -o tsv)
  echo "postprovision: Created fixed SP $FIXED_SP_ID."
else
  echo "postprovision: Fixed SP already exists ($FIXED_SP_ID)."
fi

echo "postprovision: Granting tenant-wide consent: proxy → fixed mcp.access..."
az rest --method POST \
  --uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" \
  --body "{\"clientId\":\"$PROXY_SP_ID\",\"consentType\":\"AllPrincipals\",\"resourceId\":\"$FIXED_SP_ID\",\"scope\":\"mcp.access offline_access openid\"}" \
  --output none 2>/dev/null \
  && echo "postprovision: Consent grant created." \
  || echo "postprovision: Consent grant already exists or non-fatal error — continuing."

RESOURCE_GROUP_SUFFIX=${AZURE_RESOURCE_GROUP#rg-}
REPRO_SERVER_URL="https://${WEB_APP_NAME}.azurewebsites.net"
FIXED_SERVER_URL="https://${WEB_APP_NAME}-staging.azurewebsites.net"
REPRO_AUDIENCE="api://cloud-helper-mcp-repro-${RESOURCE_GROUP_SUFFIX}"
FIXED_AUDIENCE="api://cloud-helper-mcp-fixed-${RESOURCE_GROUP_SUFFIX}"

cat > "$CLIENT_ENV_FILE" <<EOF
TENANT_ID=$AZURE_TENANT_ID
REPRO_CLIENT_ID=$REPRO_CLIENT_ID
FIXED_CLIENT_ID=$FIXED_CLIENT_ID
PROXY_CLIENT_ID=$PROXY_CLIENT_ID
WEB_APP_NAME=$WEB_APP_NAME
REPRO_SERVER_URL=$REPRO_SERVER_URL
FIXED_SERVER_URL=$FIXED_SERVER_URL
REPRO_AUDIENCE=$REPRO_AUDIENCE
FIXED_AUDIENCE=$FIXED_AUDIENCE
EOF

echo "Wrote $CLIENT_ENV_FILE"
sed -n '1,999p' "$CLIENT_ENV_FILE"

# Write VS Code MCP config — with OAuthProxy, VS Code authenticates directly
# via the proxy's /auth/* endpoints. No token injection via inputs needed.
mkdir -p "$ROOT_DIR/.vscode"
cat > "$VSCODE_MCP_FILE" <<EOF
{
  "servers": {
    "cloud-helper-fixed": {
      "type": "http",
      "url": "$FIXED_SERVER_URL/mcp"
    }
  }
}
EOF
echo "Wrote $VSCODE_MCP_FILE"
