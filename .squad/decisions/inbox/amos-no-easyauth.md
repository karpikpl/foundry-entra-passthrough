# amos-no-easyauth

- **Bicep changes made:** Removed the `webAppAuth` and `stagingSlotAuth` `authsettingsV2` resources from `infra/modules/appService.bicep`. Kept `WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES` in both production and staging slot app settings for now. Removed the now-unused `vscodeClientId` variable. Validated with `az bicep build --file infra/main.bicep` (exit 0).
- **Live commands run:** Attempted `az webapp auth update --resource-group rg-mcp-auth-test-direct --name cloud-helper-fastmcp-direct --enabled false`, but Azure CLI returned `Bad Request`. Applied the live disablement directly with:
  - `az resource update --ids /subscriptions/0721e282-2773-4021-af16-e00641ed5e36/resourceGroups/rg-mcp-auth-test-direct/providers/Microsoft.Web/sites/cloud-helper-fastmcp-direct/config/authsettingsV2 --api-version 2022-09-01 --set properties.platform.enabled=false`
  - `az resource update --ids /subscriptions/0721e282-2773-4021-af16-e00641ed5e36/resourceGroups/rg-mcp-auth-test-direct/providers/Microsoft.Web/sites/cloud-helper-fastmcp-direct/slots/staging/config/authsettingsV2 --api-version 2022-09-01 --set properties.platform.enabled=false`
- **Smoke test results:**
  - `GET https://cloud-helper-fastmcp-direct.azurewebsites.net/.well-known/oauth-protected-resource` → **HTTP 200**
  - `POST https://cloud-helper-fastmcp-direct.azurewebsites.net/mcp` without auth → **HTTP 401**
