### 2026-05-09T04:40:27Z: Fix Bicep compilation errors for AZD provisioning
**By:** Amos (Infra / DevOps)
**Status:** COMPLETE

**Summary:** Resolved the two Bicep compilation blockers that broke `azd provision`.

1. **Microsoft Graph extension:** Switched `infra/bicepconfig.json` from unsupported `builtin:microsoftGraphV1` to the OCI-published extension reference:
   `br:mcr.microsoft.com/bicep/extensions/microsoftgraph/v1.0:0.1.8-preview`
   This works on Bicep CLI 0.42.1, so the fallback preprovision hook path was not required.

2. **App Service duplicate config resources:** Removed the redundant `webAppSettings` resource from `infra/modules/appService.bicep`. `webAppStickyProd` already includes the full shared app settings set, so keeping both caused the duplicate `appsettings` resource-name collision.

3. **Related cleanup:** Removed the unused `environmentName` parameter from `infra/modules/appService.bicep` and the unnecessary `dependsOn` from `infra/main.bicep`.

**Verification:**
- `az bicep build --file infra/main.bicep` → exit 0
- `bicep build infra/main.bicep` → exit 0

**Impact:** `azd provision` is no longer blocked by these compile-time Bicep errors.
