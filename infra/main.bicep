// infra/main.bicep — AZD orchestrator for cloud-helper-fastmcp
// Created: 2026-05-09T04:22:42Z
//
// Calls two modules:
//   1. appRegistrations — creates two Entra app registrations (repro + fixed)
//      via the Microsoft.Graph Bicep extension.
//   2. appService — creates the App Service with production (repro) and
//      staging (fixed) slots, with CLIENT_ID/AUDIENCE/RESOURCE_HOST sticky.
//
// Deploy: azd provision
// Requires the deploying principal to have:
//   - Application.ReadWrite.OwnedBy (or Application.ReadWrite.All) on MS Graph
//   - Contributor on the resource group

targetScope = 'resourceGroup'

@description('Environment name — used to suffix and tag resources. Set via: azd env new <name>')
param environmentName string

@description('Azure region for App Service resources. Defaults to resource group location.')
param location string = resourceGroup().location

@description('Entra tenant ID. Resolved automatically from the AZD auth session via AZURE_TENANT_ID.')
param tenantId string

@description('Name of an existing App Service Plan to reuse. Leave empty to create a new B1 plan.')
param existingPlanName string = ''

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
    environmentName: environmentName
    tenantId: tenantId
    existingPlanName: existingPlanName
    reproClientId: appRegs.outputs.reproClientId
    reproAudience: appRegs.outputs.reproAudience
    fixedClientId: appRegs.outputs.fixedClientId
    fixedAudience: appRegs.outputs.fixedAudience
    tags: tags
  }
  dependsOn: [appRegs]
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
