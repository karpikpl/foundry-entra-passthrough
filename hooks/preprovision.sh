#!/usr/bin/env sh
# hooks/preprovision.sh — rotate the proxy app's client secret before re-provision
#
# On FIRST provision: PROXY_CLIENT_ID doesn't exist in the AZD env yet (the app
# registration hasn't been created). We skip here; postprovision.sh creates the
# credential after Bicep has run and stores it via `azd env set` + az CLI.
#
# On RE-PROVISION: PROXY_CLIENT_ID already exists. We create a fresh credential
# now so Bicep receives PROXY_CLIENT_SECRET as a non-empty secure parameter and
# sets it in the staging slot's CLIENT_SECRET app setting in the same deployment.
set -eu

AZD_ENV_VALUES=$(azd env get-values 2>/dev/null || true)

PROXY_CLIENT_ID=$(echo "$AZD_ENV_VALUES" | grep '^PROXY_CLIENT_ID=' | sed 's/^PROXY_CLIENT_ID=//' | tr -d '"' || true)

if [ -z "$PROXY_CLIENT_ID" ]; then
  echo "preprovision: PROXY_CLIENT_ID not yet in AZD env — first provision detected."
  echo "preprovision: Skipping client secret creation; postprovision.sh will handle it."
  exit 0
fi

echo "preprovision: Rotating client secret for proxy app ($PROXY_CLIENT_ID)..."

SECRET=$(az ad app credential reset \
  --id "$PROXY_CLIENT_ID" \
  --display-name "mcp-oauth-proxy" \
  --years 1 \
  --query password \
  --output tsv)

azd env set PROXY_CLIENT_SECRET "$SECRET"
echo "preprovision: Client secret created and stored as PROXY_CLIENT_SECRET."
