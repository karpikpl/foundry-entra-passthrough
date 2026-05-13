# Bug: OAuth Token Exchange Never Completes After Entra Login

## Problem Description

An MCP server implements the **OAuth 2.0 `authorization_code` + PKCE flow** (per MCP spec). AI agents (Azure AI Foundry) and VS Code connect to it. The OAuth flow begins correctly — users authenticate with Microsoft Entra in the browser — but **the token exchange never completes**: the client never POSTs to the `/token` endpoint after receiving the authorization code, leaving the connection hanging.

**Azure Resources:**
- MCP server: `cloud-helper-mcp` (Web App) — Subscription: *<your-subscription-name>*, RG: `<your-resource-group>`
- AI Foundry: `<your-foundry-workspace>` — Subscription: *<your-subscription-name>*, RG: `<your-resource-group>`

## Steps to Reproduce

1. Start the MCP server with OAuth 2.0 `authorization_code` + PKCE flow enabled.
2. Connect a client (Azure AI Foundry agent or VS Code) to the MCP server.
3. Client calls `GET /.well-known/oauth-authorization-server` → receives valid metadata. ✅
4. Client calls `POST /register` for dynamic client registration → succeeds. ✅
5. Client calls `GET /authorize` → server returns `302` redirect to Entra login with PKCE parameters. ✅
6. User completes Entra login in the browser → browser displays *"Sign-in successful!"*. ✅
7. Entra redirects back to the callback URI (`http://127.0.0.1:<port>/`) with the authorization code. ✅
8. **Expected:** Client exchanges the auth code by calling `POST /token`.
9. **Actual:** Client never calls `/token`. The connection hangs indefinitely. ❌

## Registered Redirect URIs (Entra + server)

- `https://foundry.azure.com/`
- `https://vscode.dev/redirect`
- `http://localhost` (any port)

## What Works (Server Confirmed)

| Endpoint | Result |
|---|---|
| `GET /.well-known/oauth-authorization-server` | Returns valid metadata |
| `POST /register` | Dynamic client registration succeeds |
| `GET /authorize` | 302 redirect to Entra login (PKCE, correct scope) |
| Entra login | User completes auth; browser shows "Sign-in successful!" |
| `POST /token` | Implemented and tested manually |

## What Fails

After Entra redirects to the callback URI (`http://127.0.0.1:<port>/`), the auth code is never exchanged. The client never POSTs to the `/token` endpoint and the connection hangs.
