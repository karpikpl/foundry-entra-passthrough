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

@description('Name of an existing App Service Plan to reuse. Leave empty to create a new B1 plan.')
param existingPlanName string = ''

@description('Client secret for the proxy Entra app — created by preprovision.sh on re-provision or postprovision.sh on first provision.')
@secure()
param proxyClientSecret string = ''

// ── Tenant context derived from the current subscription ─────────────────────
var tenantId = subscription().tenantId

// ── Shared App Service name — single source of truth for both modules ─────────
// Lifted here so appRegistrations can derive the OAuthProxy callback URI
// without creating a circular dependency on the appService module output.
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
    // Passed so appRegistrations can add the OAuthProxy callback URI to
    // fixedApp.web.redirectUris without knowing the slot hostname directly.
    webAppName: webAppName
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
    proxyClientId: appRegs.outputs.proxyClientId
    // Passed through securely — Bicep sets it as a sticky CLIENT_SECRET app
    // setting on the staging slot. Empty on first provision (postprovision.sh
    // creates the credential and updates the setting directly via az CLI).
    proxyClientSecret: proxyClientSecret
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
output PROXY_CLIENT_ID string = appRegs.outputs.proxyClientId
