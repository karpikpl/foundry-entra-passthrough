# Project Context

- **Owner:** Piotr Karpala
- **Project:** mcp-oauth — debugging and fixing an OAuth 2.0 authorization_code + PKCE flow on an MCP server (Azure Web App). After Entra login, the client never POSTs to /token — the token exchange hangs.
- **Stack:** MCP server (Azure Web App `cloud-helper-mcp`), Microsoft Entra ID, Azure AI Foundry (`foundry-kvmorale`), VS Code MCP client, OAuth 2.0 PKCE
- **Created:** 2026-05-08

## Learnings

### 2026-05-08T17:46:22Z — Cross-Agent Finding: Root cause analysis (from Holden)

**H1 (HIGH): Redirect URI mismatch** — The Entra app registration lists `http://localhost` (any port). But Entra's redirect lands on `http://127.0.0.1:<port>/`. Per RFC 8252 §8.3, loopback redirects MUST use `http://127.0.0.1` or `http://[::1]` — NOT `http://localhost`. Entra's platform may not treat these as equivalent. If client listener is on `127.0.0.1` but Entra redirects to `localhost` (or vice versa), callback never arrives.

**H2 (HIGH): SDK may not implement token exchange** — MCP specification defines server-side OAuth support, but client-side token exchange may not be in MCP client SDK. If the SDK relies on host application (VS Code / AI Foundry) to complete exchange, and host doesn't know the MCP server's `/token` endpoint, no POST ever happens.

**Action items for Naomi:**
1. Inspect `/.well-known/oauth-authorization-server` response — what `redirect_uris` are advertised?
2. Check `/authorize` endpoint — what `redirect_uri` does client send? Does server validate?
3. Check CORS headers on `/token`
4. Add request logging to `/token` endpoint
5. Check if server has a `/callback` endpoint that proxies the OAuth flow

**See:** `.squad/decisions/inbox/holden-oauth-root-cause-analysis.md` for full hypothesis list and investigation work plan

