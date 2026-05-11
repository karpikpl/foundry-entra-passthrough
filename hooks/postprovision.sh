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
require_var WEB_APP_NAME
require_var AZURE_RESOURCE_GROUP

# ── Client secret (first provision only) ──────────────────────────────────────
# On re-provision, preprovision.sh already created FIXED_CLIENT_SECRET and Bicep
# deployed it to the staging slot. On first provision, FIXED_CLIENT_SECRET is
# empty (Bicep received "" and set CLIENT_SECRET=""). We create it here and push
# it directly to the staging slot app settings via az CLI.
FIXED_CLIENT_SECRET_VAL=${FIXED_CLIENT_SECRET:-}

if [ -z "$FIXED_CLIENT_SECRET_VAL" ]; then
  echo "postprovision: First provision detected — creating client secret for fixed app ($FIXED_CLIENT_ID)..."
  FIXED_CLIENT_SECRET_VAL=$(az ad app credential reset \
    --id "$FIXED_CLIENT_ID" \
    --display-name "mcp-oauth-proxy" \
    --years 1 \
    --query password \
    --output tsv)

  azd env set FIXED_CLIENT_SECRET "$FIXED_CLIENT_SECRET_VAL"

  # Push directly to the staging slot since Bicep already ran with an empty value.
  az webapp config appsettings set \
    --name "$WEB_APP_NAME" \
    --slot staging \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --settings "CLIENT_SECRET=$FIXED_CLIENT_SECRET_VAL" \
    --output none

  echo "postprovision: CLIENT_SECRET set on staging slot."
else
  echo "postprovision: FIXED_CLIENT_SECRET already set (re-provision) — skipping credential creation."
fi

# ── Admin consent for mcp.access scope ───────────────────────────────────────
# Entra requires either user consent or admin consent before tokens can be issued
# for a scope. WAM (Windows Auth Manager) in VS Code performs silent SSO which
# bypasses the interactive consent UI, causing AADSTS65001 at token exchange.
# Granting admin consent (AllPrincipals) avoids per-user consent prompts entirely.
#
# This is idempotent: if a grant already exists for this SP, the POST returns 409
# and we ignore it.
echo "postprovision: Ensuring service principal exists for fixed app..."
FIXED_SP_ID=$(az ad sp list --filter "appId eq '$FIXED_CLIENT_ID'" --query "[0].id" -o tsv 2>/dev/null)
if [ -z "$FIXED_SP_ID" ]; then
  FIXED_SP_ID=$(az ad sp create --id "$FIXED_CLIENT_ID" --query id -o tsv)
  echo "postprovision: Created service principal $FIXED_SP_ID."
else
  echo "postprovision: Service principal already exists ($FIXED_SP_ID)."
fi

echo "postprovision: Granting admin consent for mcp.access scope..."
az rest --method POST \
  --uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" \
  --body "{\"clientId\":\"$FIXED_SP_ID\",\"consentType\":\"AllPrincipals\",\"resourceId\":\"$FIXED_SP_ID\",\"scope\":\"mcp.access offline_access openid\"}" \
  --output none 2>/dev/null \
  && echo "postprovision: Admin consent granted." \
  || echo "postprovision: Admin consent grant returned non-zero (may already exist — continuing)."

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
