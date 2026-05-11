// infra/modules/appService.bicep
// Updated: 2026-05-11 for direct-Entra FastMCP auth.
//
// Provisions the cloud-helper-fastmcp App Service with two slots:
//
//   production slot → cloud-helper-mcp-repro auth profile
//   staging slot    → cloud-helper-mcp-fixed auth profile
//
// Sticky settings (CLIENT_ID, AUDIENCE, RESOURCE_HOST, TENANT_ID/AZURE_TENANT_ID)
// ensure a slot swap never silently changes which app registration each slot uses.

targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string

@description('Entra tenant ID.')
param tenantId string

@description('App Service name — single source of truth from main.bicep.')
param webAppName string

@description('Name of an existing App Service Plan to reuse. Empty = create new S1 plan.')
param existingPlanName string = ''

@description('Client ID of the repro app registration.')
param reproClientId string

@description('Full audience URI (api://...) of the repro app.')
param reproAudience string

@description('Client ID of the fixed app registration.')
param fixedAppId string

@description('Full audience URI (api://...) of the fixed app.')
param fixedAudience string

@description('Tags to apply to all resources.')
param tags object = {}

var stagingSlotName = 'staging'
var planName = 'asp-${webAppName}'

resource existingPlan 'Microsoft.Web/serverfarms@2022-09-01' existing = if (!empty(existingPlanName)) {
  name: existingPlanName
}

resource newPlan 'Microsoft.Web/serverfarms@2022-09-01' = if (empty(existingPlanName)) {
  name: planName
  location: location
  tags: tags
  kind: 'linux'
  sku: {
    name: 'S1'
    tier: 'Standard'
    size: 'S1'
    capacity: 1
  }
  properties: {
    reserved: true
  }
}

var planId = empty(existingPlanName) ? newPlan.id : existingPlan.id

resource webApp 'Microsoft.Web/sites@2022-09-01' = {
  name: webAppName
  location: location
  tags: union(tags, {
    'azd-service-name': 'server'
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
      appCommandLine: 'bash startup.sh'
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
    }
  }
}

resource webAppSlotSettings 'Microsoft.Web/sites/config@2022-09-01' = {
  name: 'slotConfigNames'
  parent: webApp
  properties: {
    appSettingNames: [
      'CLIENT_ID'
      'AUDIENCE'
      'RESOURCE_APP_ID'
      'RESOURCE_HOST'
      'TENANT_ID'
      'AZURE_TENANT_ID'
    ]
  }
}

resource webAppStickyProd 'Microsoft.Web/sites/config@2022-09-01' = {
  name: 'appsettings'
  parent: webApp
  properties: {
    CLIENT_ID: reproClientId
    AUDIENCE: reproAudience
    RESOURCE_APP_ID: reproClientId
    RESOURCE_HOST: '${webAppName}.azurewebsites.net'
    TENANT_ID: tenantId
    AZURE_TENANT_ID: tenantId
    PORT: '8000'
    SCM_DO_BUILD_DURING_DEPLOYMENT: 'true'
    WEBSITES_PORT: '8000'
    PYTHON_ENABLE_GUNICORN_MULTIWORKERS: 'true'
  }
}

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
      appCommandLine: 'bash startup.sh'
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
    }
  }
}

resource stagingSlotSettings 'Microsoft.Web/sites/slots/config@2022-09-01' = {
  name: 'appsettings'
  parent: stagingSlot
  properties: {
    CLIENT_ID: fixedAppId
    AUDIENCE: fixedAudience
    RESOURCE_APP_ID: fixedAppId
    RESOURCE_HOST: '${webAppName}-staging.azurewebsites.net'
    TENANT_ID: tenantId
    AZURE_TENANT_ID: tenantId
    PORT: '8000'
    SCM_DO_BUILD_DURING_DEPLOYMENT: 'true'
    WEBSITES_PORT: '8000'
    PYTHON_ENABLE_GUNICORN_MULTIWORKERS: 'true'
  }
}

output webAppName string = webApp.name
output webAppHostname string = webApp.properties.defaultHostName
output stagingHostname string = stagingSlot.properties.defaultHostName
output planId string = planId
