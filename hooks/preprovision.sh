#!/usr/bin/env sh
# hooks/preprovision.sh — rotate the fixed app's client secret before re-provision
#
# On FIRST provision: FIXED_CLIENT_ID doesn't exist in the AZD env yet (the app
# registration hasn't been created). We skip here; postprovision.sh creates the
# credential after Bicep has run and stores it via `azd env set` + az CLI.
#
# On RE-PROVISION: FIXED_CLIENT_ID already exists. We create a fresh credential
# now so Bicep receives FIXED_CLIENT_SECRET as a non-empty secure parameter and
# sets it in the staging slot's CLIENT_SECRET app setting in the same deployment.
# This avoids a separate postprovision az CLI call on re-provision.
set -eu

AZD_ENV_VALUES=$(azd env get-values 2>/dev/null || true)

# Extract FIXED_CLIENT_ID if already provisioned
FIXED_CLIENT_ID=$(echo "$AZD_ENV_VALUES" | grep '^FIXED_CLIENT_ID=' | sed 's/^FIXED_CLIENT_ID=//' | tr -d '"' || true)

if [ -z "$FIXED_CLIENT_ID" ]; then
  echo "preprovision: FIXED_CLIENT_ID not yet in AZD env — first provision detected."
  echo "preprovision: Skipping client secret creation; postprovision.sh will handle it."
  exit 0
fi

echo "preprovision: Rotating client secret for fixed app ($FIXED_CLIENT_ID)..."

# az ad app credential reset removes all existing password credentials and
# creates a new one. --append would keep old ones; omitting it rotates cleanly.
SECRET=$(az ad app credential reset \
  --id "$FIXED_CLIENT_ID" \
  --display-name "mcp-oauth-proxy" \
  --years 1 \
  --query password \
  --output tsv)

azd env set FIXED_CLIENT_SECRET "$SECRET"
echo "preprovision: Client secret created and stored as FIXED_CLIENT_SECRET."
echo "preprovision: Bicep will pass it to the staging slot CLIENT_SECRET app setting."
