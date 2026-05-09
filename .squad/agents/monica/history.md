# Monica — Research History

## Project Context
- **Project:** Intel MCP OAuth bug — cloud-helper-mcp Azure Web App
- **Stack:** MCP server (Azure Web App), OAuth 2.0 PKCE, Entra ID, AI Foundry, VS Code
- **Bug:** After Entra login, client never calls POST /token. Auth code received but not exchanged.
- **User:** Piotr Karpala
- **Team:** Holden (Lead), Naomi (Backend), Amos (Infra), Alex (Client), Drummer (QA), Monica (Researcher)
- **Repo root:** /home/pkarpala/projects/intel/mcp-oauth

## Learnings

### 2026-05-08T17:50:48Z: MCP OAuth PKCE client support research (cloud-helper-mcp)
**Brief:** Investigate H2: does AI Foundry / VS Code support the full OAuth PKCE token exchange for MCP? Who owns the /token POST?

**Findings — MCP Python SDK:**
- `OAuthClientProvider` in `src/mcp/client/auth/oauth2.py` DOES implement the full auth_code + PKCE token exchange
- The SDK requires the host application to provide a `callback_handler` (async callable) that starts a local HTTP server on the redirect URI and returns the auth code when the browser lands there
- If no server is listening on the redirect URI, `callback_handler` never returns → token exchange never fires

**Findings — VS Code:**
- VS Code uses `IAuthenticationService` (its own auth framework) for MCP HTTP auth
- `McpServerTransportHTTPOAuth` only has `clientId?: string` — no redirect URI, no callback_handler
- VS Code registered redirect URI is `https://vscode.dev/redirect`, NOT `http://127.0.0.1:<port>/`
- VS Code acquires Entra tokens directly and presents them as Bearer tokens to the MCP server
- VS Code does NOT call the MCP server's /token endpoint — it bypasses the proxy-AS role entirely

**Findings — AI Foundry:**
- Foundry's 2026 OAuth Passthrough feature handles token relay server-side when configured in Foundry portal
- Redirect URI: `https://foundry.azure.com/` — not loopback
- Without OAuth passthrough configured, Foundry does not call the MCP server's /token
- Pre-2026 / SDK ≤1.0.0b11: Foundry does not natively route user tokens to MCP tools

**Findings — MCP spec:**
- Spec assigns token exchange to the CLIENT (`C->>M: Token Request with code + code_verifier`)
- The spec does not designate which component (SDK vs host app) makes the call

**Onsemi prior analysis (critical):**
- Working pattern is APIM + PRM (RFC 9728): MCP server = Resource Server, Entra = AS, clients get tokens from Entra directly
- The onsemi `labs/mcp-prm-oauth` sample is the reference implementation
- AADSTS9002326: occurs when `web:` platform type is used instead of `spa:` for MSAL.js/PKCE clients (fix: use `spa: { redirectUris }` in Bicep)
- Gandalf-8: Foundry OAuth passthrough is server-side (configured in portal), NOT in SDK

**H2 verdict:** CONFIRMED with nuance — VS Code/Foundry bypass the MCP server's /token endpoint architecturally; the Python SDK itself implements token exchange correctly

**Architectural recommendation:** Switch `cloud-helper-mcp` from AS-mode to RS-mode:
1. Remove proxy /authorize and /token endpoints
2. Add `/.well-known/oauth-protected-resource` (RFC 9728 PRM) pointing to Entra
3. Validate incoming Bearer tokens using APIM or middleware
4. This is what VS Code and Foundry actually expect

**Sources:** onsemi Gandalf-7/8, Legolas-4/5/6 histories; MCP spec `authorization.mdx`; MCP Python SDK `oauth2.py`; VS Code `mcpTypes.ts`, `mcpServerActions.ts`; onsemi `gandalf-mcp-prm-oauth.md`

### 2026-05-08T18:02:45Z — CROSS-PROPAGATION: H2 CONFIRMED + RS-MODE ARCHITECTURAL FIX REQUIRED

**Monica's research confirms H2 with architectural clarity:**

- **H2 CONFIRMED (HIGH):** VS Code and AI Foundry do NOT invoke the MCP server's /token endpoint. They use their own OAuth frameworks that obtain Bearer tokens directly from Entra ID (`https://vscode.dev/redirect` for VS Code, `https://foundry.azure.com/` for Foundry) and bypass the MCP server's Authorization Server role entirely.
- **Architectural root cause:** The intel `cloud-helper-mcp` acts as an MCP Authorization Server, but production clients expect Resource Server behavior (RFC 9728 PRM).
- **Reference:** onsemi `labs/mcp-prm-oauth` demonstrates the correct pattern: MCP server publishes `/.well-known/oauth-protected-resource` pointing to Entra, validates Bearer tokens using JWT validation.
- **Key evidence:** MCP spec, VS Code source (`IAuthenticationService`, `https://vscode.dev/redirect`), Foundry OAuth passthrough docs, MCP Python SDK analysis.

**Recommended RS-mode switch:**
1. Remove `/authorize` and `/token` proxy endpoints
2. Add `/.well-known/oauth-protected-resource` (RFC 9728 PRM) → Entra
3. Validate Bearer tokens via JWT validation middleware
4. Clients automatically use this metadata to route tokens through Entra

**Status:** H1 + H2 both confirmed. Fix strategy ready for Phase 2 implementation.
