// Creates a private DNS zone + private endpoint for the App Service MCP server,
// then registers it as a RemoteTool connection in AI Foundry using
// Entra Identity Passthrough (the caller's Entra token is forwarded on each call).

param location string
param tags object = {}
param vnetResourceId string
param peSubnetResourceId string
param aiFoundryName string

@export()
type apiType = {
  name: string
  resourceId: string
  @description('Use "sites" for App Service, "managedEnvironments" for ACA')
  type: 'sites' | 'managedEnvironments'
  @description('e.g. privatelink.azurewebsites.net')
  dnsZoneName: string
  @description('Base URL of the MCP server — used as the Foundry connection target')
  uri: string
  @description('Audience (api://...) of the app registration for Entra passthrough')
  audience: string
  @description('Client ID of the app registration')
  clientId: string
}

param apis apiType[] = []

// ── Private DNS zone for App Service ─────────────────────────────────────────
module dnsSites 'br/public:avm/res/network/private-dns-zone:0.8.1' = {
  name: 'dns-sites'
  params: {
    tags: tags
    name: 'privatelink.azurewebsites.net'
    virtualNetworkLinks: [
      {
        virtualNetworkResourceId: vnetResourceId
      }
    ]
  }
}

// ── Private endpoints ─────────────────────────────────────────────────────────
module privateEndpoints '../networking/private-endpoint.bicep' = [
  for (api, i) in apis: {
    name: 'pe-${api.name}'
    params: {
      tags: tags
      privateEndpointName: 'pe-${api.name}'
      location: location
      subnetId: peSubnetResourceId
      targetResourceId: api.resourceId
      groupIds: [api.type]
      zoneConfigs: [
        {
          name: api.dnsZoneName
          privateDnsZoneId: dnsSites.outputs.resourceId
        }
      ]
    }
  }
]

// ── Foundry RemoteTool connections — Entra User Token Passthrough ─────────────
// authType 'UserEntraToken' = Foundry forwards the calling user's Entra token
// (scoped to audience) to the MCP server on each call. No client secret needed.

resource foundry 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: aiFoundryName
}

resource mcpConnections 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = [
  for (api, i) in apis: {
    name: 'MCP-${api.name}'
    parent: foundry
    properties: {
      category: 'RemoteTool'
      target: api.uri
      authType: 'UserEntraToken'
      isSharedToAll: true
      metadata: {
        type: 'custom_MCP'
        audience: api.audience
        clientId: api.clientId
      }
    }
  }
]
