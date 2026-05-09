// infra/modules/appService.bicep
// Created: 2026-05-09T04:22:42Z
//
// Provisions the cloud-helper-fastmcp App Service with two slots:
//
//   production slot → cloud-helper-mcp-repro auth profile  (H1 bug preserved)
//   staging slot    → cloud-helper-mcp-fixed auth profile  (H1 corrected)
//
// Slot assignment is LOCKED per Piotr directive (2026-05-09, decisions.md D9).
//
// Sticky settings (CLIENT_ID, AUDIENCE, RESOURCE_HOST, AZURE_TENANT_ID) ensure
// a slot swap (code rollout) NEVER silently changes which app reg is in use.
//
// The App Service is tagged with azd-service-name=server so AZD knows which
// App Service to deploy the FastMCP Python code to.

targetScope = 'resourceGroup'

// ── Parameters ────────────────────────────────────────────────────────────────

@description('Azure region for all resources.')
param location string

@description('Environment name — used for tagging.')
param environmentName string

@description('Entra tenant ID.')
param tenantId string

@description('Name of an existing App Service Plan to reuse. Empty = create new B1 plan.')
param existingPlanName string = ''

@description('Client ID of the repro app registration.')
param reproClientId string

@description('Full audience (api://.../mcp.access) of the repro app.')
param reproAudience string

@description('Client ID of the fixed app registration.')
param fixedClientId string

@description('Full audience (api://.../mcp.access) of the fixed app.')
param fixedAudience string

@description('Tags to apply to all resources.')
param tags object = {}

// ── Derived names ─────────────────────────────────────────────────────────────
var webAppName = 'cloud-helper-fastmcp'
var stagingSlotName = 'staging'

// ── App Service Plan ──────────────────────────────────────────────────────────
// Reuse an existing plan if existingPlanName is provided; otherwise create B1.
resource existingPlan 'Microsoft.Web/serverfarms@2022-09-01' existing = if (!empty(existingPlanName)) {
  name: existingPlanName
}

resource newPlan 'Microsoft.Web/serverfarms@2022-09-01' = if (empty(existingPlanName)) {
  name: 'asp-cloud-helper-fastmcp'
  location: location
  tags: tags
  kind: 'linux'
  sku: {
    name: 'B1'
    tier: 'Basic'
    size: 'B1'
    capacity: 1
  }
  properties: {
    reserved: true  // required for Linux
  }
}

// Resolve the plan resource ID regardless of whether we reused or created it
var planId = empty(existingPlanName) ? newPlan.id : existingPlan.id

// ── App Service (production slot = repro) ─────────────────────────────────────
resource webApp 'Microsoft.Web/sites@2022-09-01' = {
  name: webAppName
  location: location
  tags: union(tags, {
    'azd-service-name': 'server'  // AZD deployment target discovery
  })
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: planId
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.12'
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
    }
  }
}

// ── Non-sticky app settings (shared, swappable) ───────────────────────────────
// These travel with the code on slot swap (correct behaviour for shared config).
resource webAppSettings 'Microsoft.Web/sites/config@2022-09-01' = {
  name: 'appsettings'
  parent: webApp
  properties: {
    AZURE_TENANT_ID: tenantId
    PORT: '8000'
    SCM_DO_BUILD_DURING_DEPLOYMENT: 'true'
    WEBSITES_PORT: '8000'
    PYTHON_ENABLE_GUNICORN_MULTIWORKERS: 'true'
  }
}

// ── Sticky slot settings — production slot = REPRO profile ───────────────────
// These do NOT travel with a slot swap; each slot keeps its own auth identity.
resource webAppSlotSettings 'Microsoft.Web/sites/config@2022-09-01' = {
  name: 'slotConfigNames'
  parent: webApp
  properties: {
    appSettingNames: [
      'CLIENT_ID'
      'AUDIENCE'
      'RESOURCE_HOST'
      'AZURE_TENANT_ID'
    ]
  }
}

// Sticky values for production slot (repro — H1 bug preserved)
resource webAppStickyProd 'Microsoft.Web/sites/config@2022-09-01' = {
  name: 'appsettings'
  parent: webApp
  properties: {
    // Sticky — repro profile
    CLIENT_ID: reproClientId
    AUDIENCE: reproAudience
    RESOURCE_HOST: '${webAppName}.azurewebsites.net'
    AZURE_TENANT_ID: tenantId
    // Non-sticky shared settings (duplicated here so both configs are set together)
    PORT: '8000'
    SCM_DO_BUILD_DURING_DEPLOYMENT: 'true'
    WEBSITES_PORT: '8000'
    PYTHON_ENABLE_GUNICORN_MULTIWORKERS: 'true'
  }
  dependsOn: [webAppSlotSettings]
}

// ── Staging slot (fixed — H1 corrected) ──────────────────────────────────────
resource stagingSlot 'Microsoft.Web/sites/slots@2022-09-01' = {
  name: stagingSlotName
  parent: webApp
  location: location
  tags: tags
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: planId
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.12'
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
    }
  }
}

// Sticky values for staging slot (fixed — H1 corrected)
resource stagingSlotSettings 'Microsoft.Web/sites/slots/config@2022-09-01' = {
  name: 'appsettings'
  parent: stagingSlot
  properties: {
    // Sticky — fixed profile
    CLIENT_ID: fixedClientId
    AUDIENCE: fixedAudience
    RESOURCE_HOST: '${webAppName}-staging.azurewebsites.net'
    AZURE_TENANT_ID: tenantId
    // Non-sticky shared settings
    PORT: '8000'
    SCM_DO_BUILD_DURING_DEPLOYMENT: 'true'
    WEBSITES_PORT: '8000'
    PYTHON_ENABLE_GUNICORN_MULTIWORKERS: 'true'
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────
output webAppName string = webApp.name
output webAppHostname string = webApp.properties.defaultHostName
output stagingHostname string = stagingSlot.properties.defaultHostName
output planId string = planId
