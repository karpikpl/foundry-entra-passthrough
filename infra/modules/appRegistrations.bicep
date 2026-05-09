// infra/modules/appRegistrations.bicep
// Created: 2026-05-09T04:22:42Z
//
// Creates two Entra app registrations for the mcp-oauth repro/fixed demo:
//
//   cloud-helper-mcp-repro
//     public-client redirect URIs : http://localhost          (H1 bug preserved)
//     web redirect URIs           : https://foundry.azure.com/, https://vscode.dev/redirect
//     exposes scope               : mcp.access
//     token version               : 2
//
//   cloud-helper-mcp-fixed
//     public-client redirect URIs : http://localhost, http://127.0.0.1  (H1 fixed)
//     web redirect URIs           : https://foundry.azure.com/, https://vscode.dev/redirect
//     exposes scope               : mcp.access
//     token version               : 2
//
// REQUIRES: Microsoft.Graph Bicep extension (bicepconfig.json enables it).
// The deploying principal must have Application.ReadWrite.OwnedBy (or higher)
// on the Microsoft Graph API in the target Entra tenant.
//
// identifierUris limitation:
//   Microsoft.Graph Bicep cannot set identifierUris to api://{appId} in the
//   same resource block (self-referential). We use api://cloud-helper-mcp-repro
//   and api://cloud-helper-mcp-fixed instead — valid, unique, and known at
//   deploy time. If you need the canonical api://{appId} format, run:
//     az ad app update --id <APP_ID> --identifier-uris "api://<APP_ID>"
//   after provisioning. See infra/README.md for the optional post-provision step.

extension microsoftGraphV1

@description('Environment name — disambiguates multiple AZD environments in the same tenant.')
param environmentName string

// ── Deterministic scope GUIDs (stable across deployments in the same env) ────
// guid() is deterministic for the same inputs — ensures idempotent re-deploys.
var reproScopeId = guid('cloud-helper-mcp-repro', environmentName, 'mcp.access')
var fixedScopeId = guid('cloud-helper-mcp-fixed', environmentName, 'mcp.access')

// Friendly display suffix for multi-env tenants (omitted when env = 'production')
var envSuffix = environmentName == 'production' ? '' : '-${environmentName}'

var reproName = 'cloud-helper-mcp-repro${envSuffix}'
var fixedName = 'cloud-helper-mcp-fixed${envSuffix}'

// identifierUris — using display-name based URIs (see file header for rationale)
var reproIdentifierUri = 'api://${reproName}'
var fixedIdentifierUri = 'api://${fixedName}'

// Common web redirect URIs shared by both app registrations
var webRedirectUris = [
  'https://foundry.azure.com/'
  'https://vscode.dev/redirect'
]

// ── Repro app registration (H1 bug preserved: localhost only) ─────────────────
resource reproApp 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: reproName
  displayName: reproName
  signInAudience: 'AzureADMyOrg'

  // Public-client (Mobile/Desktop) platform — allows dynamic ports on loopback
  publicClient: {
    redirectUris: [
      'http://localhost'
    ]
  }

  // Web platform — for Foundry and VS Code browser-based clients
  web: {
    redirectUris: webRedirectUris
    implicitGrantSettings: {
      enableAccessTokenIssuance: false
      enableIdTokenIssuance: false
    }
  }

  // RS-mode: expose mcp.access delegated scope; token v2
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

// ── Fixed app registration (H1 corrected: localhost + 127.0.0.1) ──────────────
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
  }

  identifierUris: [
    fixedIdentifierUri
  ]
}

// ── Outputs ───────────────────────────────────────────────────────────────────
@description('Client ID of the repro app registration (H1 bug preserved).')
output reproClientId string = reproApp.appId

@description('Client ID of the fixed app registration (H1 corrected).')
output fixedClientId string = fixedApp.appId

@description('Full audience/scope for the repro app (used as AUDIENCE sticky setting on production slot).')
output reproAudience string = '${reproIdentifierUri}/mcp.access'

@description('Full audience/scope for the fixed app (used as AUDIENCE sticky setting on staging slot).')
output fixedAudience string = '${fixedIdentifierUri}/mcp.access'

@description('Application ID URI for repro app (for Bearer token validation).')
output reproIdentifierUri string = reproIdentifierUri

@description('Application ID URI for fixed app (for Bearer token validation).')
output fixedIdentifierUri string = fixedIdentifierUri
