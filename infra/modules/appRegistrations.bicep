// infra/modules/appRegistrations.bicep
// Updated: 2026-05-11 for direct-Entra resource-server mode.
//
// Creates Entra resource-server app registration for the mcp-oauth
// demo. The app exposes the mcp.access delegated scope and creates the
// corresponding service principal in-tenant. The app additionally
// pre-authorizes VS Code so it can request the scope directly.

extension microsoftGraphV1

@description('Environment name — required in every app registration name so parallel AZD environments stay unique in the same tenant.')
param environmentName string

var vscodeClientId = 'aebc6443-996d-45c2-90f0-388ff96faa56'

// ── Deterministic scope GUIDs (stable across deployments in the same env) ────
var scopeId = guid('cloud-helper-mcp', environmentName, 'mcp.access')

// Always suffix app registration names with the AZD environment name so
// parallel environments never reuse the same Entra display names.
var envSuffix = '-${environmentName}'

var name = 'cloud-helper-mcp${envSuffix}'

// identifierUris — using display-name based URIs (self-referential api://{appId}
// can't be set in the same Graph resource declaration)
var identifierUri = 'api://${name}'

var webRedirectUris = [
  'https://ai.azure.com/'
  'https://vscode.dev/redirect'
]

// ── app registration (localhost + 127.0.0.1, VS Code pre-authorized) ───
resource app 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: name
  displayName: name
  signInAudience: 'AzureADMyOrg'
  isFallbackPublicClient: true  // Allows PKCE token exchange without client_secret (required for Foundry OAuth Identity Passthrough)

  publicClient: {
    redirectUris: [
      'http://localhost'
      'http://127.0.0.1'
    ]
  }

  web: {
    redirectUris: webRedirectUris
    implicitGrantSettings: {
      enableAccessTokenIssuance: false
      enableIdTokenIssuance: false
    }
  }

  api: {
    requestedAccessTokenVersion: 2
    oauth2PermissionScopes: [
      {
        id: scopeId
        adminConsentDescription: 'Allows the app to call the cloud-helper MCP server on behalf of the user.'
        adminConsentDisplayName: 'Access MCP server'
        isEnabled: true
        type: 'User'
        userConsentDescription: 'Access the cloud-helper MCP server on your behalf.'
        userConsentDisplayName: 'Access MCP server'
        value: 'mcp.access'
      }
    ]
    preAuthorizedApplications: [
      {
        appId: vscodeClientId
        delegatedPermissionIds: [
          scopeId
        ]
      }
    ]
  }

  identifierUris: [
    identifierUri
  ]
}

resource servicePrincipal 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: app.appId
  accountEnabled: true
}

// ── Outputs ───────────────────────────────────────────────────────────────────
@description('Client ID of the app registration (H1 corrected).')
output clientId string = app.appId

@description('Audience for the app — the api:// identifier URI.')
output audience string = identifierUri

@description('Application ID URI for the app.')
output identifierUri string = identifierUri
