// infra/main.bicep — AZD orchestrator for cloud-helper-fastmcp
// Updated: 2026-05-11 for direct-Entra pattern (no OAuthProxy client app)
//
// Calls two modules:
//   1. appRegistrations — creates the repro + fixed Entra resource-server app
//      registrations via the Microsoft.Graph Bicep extension.
//   2. appService — creates the App Service with production (repro) and
//      staging (fixed) slots configured for EasyAuth v2 + PRM.

targetScope = 'resourceGroup'

@description('Environment name — used to suffix and tag resources. Set via: azd env new <name>')
param environmentName string

@description('Azure region for App Service resources. Defaults to resource group location.')
param location string = resourceGroup().location

@description('Name of an existing App Service Plan to reuse. Leave empty to create a new S1 plan.')
param existingPlanName string = ''

// ── Tenant context derived from the current subscription ─────────────────────
var tenantId = subscription().tenantId

// ── Shared App Service name — single source of truth ────────────────────────
var webAppName = 'cloud-helper-fastmcp'

// ── Tags applied to all ARM resources ────────────────────────────────────────
var tags = {
  project: 'cloud-helper-fastmcp'
  environment: environmentName
  managedBy: 'azd'
}

// ── App Registrations (Entra, via MS Graph Bicep extension) ──────────────────
module appRegs './modules/appRegistrations.bicep' = {
  name: 'appRegistrations-${environmentName}'
  params: {
    environmentName: environmentName
  }
}

// ── App Service + slots ───────────────────────────────────────────────────────
module appSvc './modules/appService.bicep' = {
  name: 'appService-${environmentName}'
  params: {
    location: location
    tenantId: tenantId
    webAppName: webAppName
    existingPlanName: existingPlanName
    reproClientId: appRegs.outputs.reproClientId
    reproAudience: appRegs.outputs.reproAudience
    fixedAudience: appRegs.outputs.fixedAudience
    fixedAppId: appRegs.outputs.fixedClientId
    tags: tags
  }
}

// ── Outputs (available via `azd env get-values`) ─────────────────────────────
output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenantId
output WEB_APP_NAME string = appSvc.outputs.webAppName
output WEB_APP_HOSTNAME string = appSvc.outputs.webAppHostname
output REPRO_CLIENT_ID string = appRegs.outputs.reproClientId
output REPRO_AUDIENCE string = appRegs.outputs.reproAudience
output FIXED_CLIENT_ID string = appRegs.outputs.fixedClientId
output FIXED_AUDIENCE string = appRegs.outputs.fixedAudience
