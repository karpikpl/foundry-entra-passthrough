// infra/modules/appService.bicep
// Updated: 2026-05-12 simplified to single production slot.
//
// Provisions the cloud-helper-fastmcp App Service — single production slot
// wired to the cloud-helper-mcp-fixed Entra app registration.
// Basic B1 plan (slots not supported or needed).

targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string

@description('Entra tenant ID.')
param tenantId string

@description('App Service name — single source of truth from main.bicep.')
param webAppName string

@description('Name of an existing App Service Plan to reuse. Empty = create new B1 plan.')
param existingPlanName string = ''

@description('Client ID of the fixed app registration.')
param fixedAppId string

@description('Full audience URI (api://...) of the fixed app.')
param fixedAudience string

@description('Tags to apply to all resources.')
param tags object = {}

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
    name: 'B1'
    tier: 'Basic'
    size: 'B1'
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

resource webAppStickyProd 'Microsoft.Web/sites/config@2022-09-01' = {
  name: 'appsettings'
  parent: webApp
  properties: {
    CLIENT_ID: fixedAppId
    AUDIENCE: fixedAudience
    RESOURCE_APP_ID: fixedAppId
    RESOURCE_HOST: '${webAppName}.azurewebsites.net'
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
output planId string = planId
