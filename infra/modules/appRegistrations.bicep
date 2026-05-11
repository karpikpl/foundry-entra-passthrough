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

@description('App Service name — used to construct the OAuthProxy callback URI for the staging slot.')
param webAppName string

// ── Deterministic scope GUIDs (stable across deployments in the same env) ────
// guid() is deterministic for the same inputs — ensures idempotent re-deploys.
var reproScopeId = guid('cloud-helper-mcp-repro', environmentName, 'mcp.access')
var fixedScopeId = guid('cloud-helper-mcp-fixed', environmentName, 'mcp.access')

// Friendly display suffix for multi-env tenants (omitted when env = 'production')
var envSuffix = environmentName == 'production' ? '' : '-${environmentName}'

var reproName = 'cloud-helper-mcp-repro${envSuffix}'
var fixedName = 'cloud-helper-mcp-fixed${envSuffix}'
var proxyName = 'cloud-helper-mcp-proxy${envSuffix}'

// identifierUris — using display-name based URIs (see file header for rationale)
var reproIdentifierUri = 'api://${reproName}'
var fixedIdentifierUri = 'api://${fixedName}'
// proxyApp is a confidential client only — it has no exposed scopes and no
// identifierUri. It requests the fixed app's mcp.access scope on behalf of users.

// Common web redirect URIs shared by both app registrations
var webRedirectUris = [
  'https://foundry.azure.com/'
  'https://vscode.dev/redirect'
]

// OAuthProxy callback URI — FastMCP's fixed redirect URI that Entra must know
// about. The proxy accepts DCR requests with dynamic callback ports from MCP
// clients, but always uses this single URI when redirecting to Entra. After
// Entra validates the user, it redirects here; the proxy then forwards to the
// original dynamic client callback. Only the fixed app needs this (the repro
// app still uses direct Entra auth with public-client redirect URIs).
var fixedProxyCallbackUri = 'https://${webAppName}-staging.azurewebsites.net/auth/callback'

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

  // Web platform — for Foundry, VS Code browser-based clients, and OAuthProxy callback
  web: {
    redirectUris: concat(webRedirectUris, [fixedProxyCallbackUri])
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

// ── Proxy app registration (OAuthProxy confidential client) ──────────────────
// Separate client app so that Entra's consent model works correctly:
//   proxy (client) requests → fixed (resource) mcp.access scope
// When a single app requests its own scope the consent check behaves
// inconsistently; a separate client/resource pair resolves this cleanly.
resource proxyApp 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: proxyName
  displayName: proxyName
  signInAudience: 'AzureADMyOrg'

  web: {
    redirectUris: [fixedProxyCallbackUri]
    implicitGrantSettings: {
      enableAccessTokenIssuance: false
      enableIdTokenIssuance: false
    }
  }

  // Declare the delegated permission the proxy needs so admin consent and the
  // Entra consent UI both work correctly out of the box.
  requiredResourceAccess: [
    {
      // fixed app is the resource being accessed
      resourceAppId: fixedApp.appId
      resourceAccess: [
        {
          // fixed app's mcp.access delegated scope
          id: fixedScopeId
          type: 'Scope'
        }
      ]
    }
  ]
}

// ── Outputs ───────────────────────────────────────────────────────────────────

@description('Client ID of the repro app registration (H1 bug preserved).')
output reproClientId string = reproApp.appId

@description('Client ID of the fixed app registration (H1 corrected).')
output fixedClientId string = fixedApp.appId

@description('Client ID of the proxy app registration (OAuthProxy confidential client).')
output proxyClientId string = proxyApp.appId

@description('Audience for the repro app — the api:// identifier URI, used both for scope construction and JWT aud validation.')
output reproAudience string = reproIdentifierUri

@description('Audience for the fixed app — the api:// identifier URI, used both for scope construction and JWT aud validation.')
output fixedAudience string = fixedIdentifierUri

@description('Application ID URI for repro app.')
output reproIdentifierUri string = reproIdentifierUri

@description('Application ID URI for fixed app.')
output fixedIdentifierUri string = fixedIdentifierUri
