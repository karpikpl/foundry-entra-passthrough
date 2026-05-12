// infra/modules/appRegistrations.bicep
// Updated: 2026-05-11 for direct-Entra resource-server mode.
//
// Creates two Entra resource-server app registrations for the mcp-oauth
// repro/fixed demo. Both expose the mcp.access delegated scope and create the
// corresponding service principals in-tenant. The fixed app additionally
// pre-authorizes VS Code so it can request the scope directly.

extension microsoftGraphV1

@description('Environment name — required in every app registration name so parallel AZD environments stay unique in the same tenant.')
param environmentName string

var vscodeClientId = 'aebc6443-996d-45c2-90f0-388ff96faa56'

// ── Deterministic scope GUIDs (stable across deployments in the same env) ────
var reproScopeId = guid('cloud-helper-mcp-repro', environmentName, 'mcp.access')
var fixedScopeId = guid('cloud-helper-mcp-fixed', environmentName, 'mcp.access')

// Always suffix app registration names with the AZD environment name so
// parallel environments never reuse the same Entra display names.
var envSuffix = '-${environmentName}'

var reproName = 'cloud-helper-mcp-repro${envSuffix}'
var fixedName = 'cloud-helper-mcp-fixed${envSuffix}'

// identifierUris — using display-name based URIs (self-referential api://{appId}
// can't be set in the same Graph resource declaration)
var reproIdentifierUri = 'api://${reproName}'
var fixedIdentifierUri = 'api://${fixedName}'

var webRedirectUris = [
  'https://ai.azure.com/'
  'https://vscode.dev/redirect'
]

// ── Repro app registration (H1 bug preserved: localhost only) ─────────────────
resource reproApp 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: reproName
  displayName: reproName
  signInAudience: 'AzureADMyOrg'

  publicClient: {
    redirectUris: [
      'http://localhost'
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
        id: reproScopeId
        adminConsentDescription: 'Allows the app to call the cloud-helper MCP server on behalf of the user (repro registration).'
        adminConsentDisplayName: 'Access MCP server (repro)'
        isEnabled: true
        type: 'User'
        userConsentDescription: 'Access the cloud-helper MCP server on your behalf.'
        userConsentDisplayName: 'Access MCP server'
        value: 'mcp.access'
      }
    ]
  }

  identifierUris: [
    reproIdentifierUri
  ]
}

// ── Fixed app registration (localhost + 127.0.0.1, VS Code pre-authorized) ───
resource fixedApp 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: fixedName
  displayName: fixedName
  signInAudience: 'AzureADMyOrg'

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
        id: fixedScopeId
        adminConsentDescription: 'Allows the app to call the cloud-helper MCP server on behalf of the user (fixed registration).'
        adminConsentDisplayName: 'Access MCP server (fixed)'
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
          fixedScopeId
        ]
      }
    ]
  }

  identifierUris: [
    fixedIdentifierUri
  ]
}

resource reproServicePrincipal 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: reproApp.appId
  accountEnabled: true
}

resource fixedServicePrincipal 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: fixedApp.appId
  accountEnabled: true
}

// ── Outputs ───────────────────────────────────────────────────────────────────

@description('Client ID of the repro app registration (H1 bug preserved).')
output reproClientId string = reproApp.appId

@description('Client ID of the fixed app registration (H1 corrected).')
output fixedClientId string = fixedApp.appId

@description('Audience for the repro app — the api:// identifier URI.')
output reproAudience string = reproIdentifierUri

@description('Audience for the fixed app — the api:// identifier URI.')
output fixedAudience string = fixedIdentifierUri

@description('Application ID URI for repro app.')
output reproIdentifierUri string = reproIdentifierUri

@description('Application ID URI for fixed app.')
output fixedIdentifierUri string = fixedIdentifierUri
