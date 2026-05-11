# MCP OAuth with Direct Entra Authentication

A reference implementation showing how to authenticate VS Code's MCP client directly with Microsoft Entra ID — no OAuth proxy layer needed.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Direct Entra MCP OAuth Flow                          │
└─────────────────────────────────────────────────────────────────────────────┘

  VS Code                                    MCP Server                 Entra ID
     │                                          │                          │
     │  1. POST /mcp                            │                          │
     │─────────────────────────────────────────►│                          │
     │  ◄─────────────────────────────────────── 401 Unauthorized         │
     │         WWW-Authenticate: Bearer         │                          │
     │         resource_metadata="/.well-known/oauth-protected-resource"  │
     │                                          │                          │
     │  2. GET /.well-known/oauth-protected-resource                       │
     │─────────────────────────────────────────►│                          │
     │  ◄─────────────────────────────────────── 200 { authorization_servers: [Entra] }
     │                                          │                          │
     │  3. VS Code recognizes Entra → uses signed-in Microsoft account     │
     │     (native account picker, no browser redirect needed)             │
     │────────────────────────────────────────────────────────────────────►│
     │  ◄──────────────────────────────────────────────────────────────────│
     │         Access token (audience = MCP server app reg)                │
     │                                          │                          │
     │  4. POST /mcp (Authorization: Bearer <token>)                       │
     │─────────────────────────────────────────►│                          │
     │                                          │ 5. Validate JWT          │
     │                                          │    (JWKS, issuer, aud)   │
     │  ◄─────────────────────────────────────── 200 OK                   │
     │         MCP response                     │                          │
     └──────────────────────────────────────────┴──────────────────────────┘
```

## Key Insight

VS Code has a built-in Microsoft account provider. When an MCP server's Protected Resource Metadata (PRM) points to Entra as the authorization server, VS Code recognizes it and uses the already-signed-in Microsoft account — **no browser redirect needed**. The only requirement is that the server's Entra app registration pre-authorizes VS Code's client ID.

## Quick Start

### 1. Configure VS Code

Create or edit `.vscode/mcp.json`:

```json
{
  "servers": {
    "cloud-helper": {
      "type": "http",
      "url": "https://cloud-helper-fastmcp-direct-staging.azurewebsites.net/mcp"
    }
  }
}
```

That's it. No `auth` block, no `clientId`, no `scopes`. VS Code discovers everything from the server's PRM.

### 2. Connect

1. Open VS Code's MCP panel (Command Palette → "MCP: List Tools")
2. VS Code shows the native account picker with your signed-in Microsoft accounts
3. Select an account → token acquired silently → connected

## Live Demo Instances

| Instance | URL | Behavior |
|----------|-----|----------|
| **Fixed (Staging)** | `https://cloud-helper-fastmcp-direct-staging.azurewebsites.net/mcp` | ✅ Works — VS Code pre-authorized |
| **Repro (Production)** | `https://cloud-helper-fastmcp-direct.azurewebsites.net/mcp` | ❌ Fails — shows the bug when VS Code is NOT pre-authorized |

## The Fix: One Line in Entra

The difference between "works" and "fails" is a single configuration:

**In the server's Entra app registration → Expose an API → Authorized client applications:**

Add VS Code's client ID: `aebc6443-996d-45c2-90f0-388ff96faa56`

This is done via `preAuthorizedApplications` in the app manifest:

```json
{
  "api": {
    "preAuthorizedApplications": [
      {
        "appId": "aebc6443-996d-45c2-90f0-388ff96faa56",
        "delegatedPermissionIds": ["<mcp.access-scope-guid>"]
      }
    ]
  }
}
```

## Architecture

- **Server:** FastMCP with `RemoteAuthProvider` + `JWTVerifier` for native JWT validation
- **Auth Pattern:** Resource Server mode (RS-mode) — no OAuth proxy
- **Discovery:** RFC 9728 Protected Resource Metadata at `/.well-known/oauth-protected-resource`
- **Tenant:** `c29d6c2b-f765-41b3-b2a2-971a14239dfd`

See [docs/architecture.md](docs/architecture.md) for the full technical deep-dive.

## Documentation

- **[Architecture Deep-Dive](docs/architecture.md)** — Auth flow, why direct-Entra works, EasyAuth comparison
- **[VS Code Setup Guide](docs/vscode-setup.md)** — Step-by-step configuration and troubleshooting

## Project Structure

```
mcp-oauth/
├── server/
│   ├── server.py       # FastMCP app with RemoteAuthProvider + JWTVerifier
│   ├── auth.py         # Entra token validation utilities
│   └── config.py       # Environment-based configuration
├── infra/
│   └── modules/
│       └── appRegistrations.bicep  # Entra app regs (repro + fixed)
├── docs/
│   ├── architecture.md # Technical deep-dive
│   └── vscode-setup.md # VS Code configuration guide
└── client/
    └── test_client.py  # Python test client for manual testing
```

## Environment Variables (Server)

| Variable | Description | Example |
|----------|-------------|---------|
| `TENANT_ID` | Entra tenant ID | `c29d6c2b-f765-41b3-b2a2-971a14239dfd` |
| `CLIENT_ID` | Server app registration client ID | `<guid>` |
| `AUDIENCE` | Token audience (usually `api://<app-name>`) | `api://cloud-helper-mcp-fixed-mcp-auth-test-direct` |
| `RESOURCE_HOST` | Server hostname | `cloud-helper-fastmcp-direct-staging.azurewebsites.net` |

## License

MIT
