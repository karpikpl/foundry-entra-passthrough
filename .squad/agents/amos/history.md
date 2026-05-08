# Project Context

- **Owner:** Piotr Karpala
- **Project:** mcp-oauth — debugging and fixing an OAuth 2.0 authorization_code + PKCE flow on an MCP server (Azure Web App). After Entra login, the client never POSTs to /token — the token exchange hangs.
- **Stack:** MCP server (Azure Web App `cloud-helper-mcp`), Microsoft Entra ID, Azure AI Foundry (`foundry-kvmorale`), VS Code MCP client, OAuth 2.0 PKCE
- **Azure Resources:** cloud-helper-mcp (RG: rg-cloud-helper-mcp, Sub: Cloud Brokers - ASC Testing), foundry-kvmorale (RG: kvmorale_Apr-16-2026, Sub: hosting-ai-sandbox)
- **Created:** 2026-05-08

## Learnings

### 2026-05-08T17:46:22Z — Cross-Agent Finding: Root cause analysis (from Holden) + User directive

**H1 (HIGH): Redirect URI mismatch** — Entra app registration may list `http://localhost` (any port), but Entra's actual redirect lands on `http://127.0.0.1:<port>/`. Per RFC 8252, loopback redirects MUST use `http://127.0.0.1` or `http://[::1]` — NOT `http://localhost`. If app registration platform type is "Web" vs "Mobile/Desktop", port matching behavior differs. Need to verify exact registered URIs and platform type.

**H5 (MEDIUM): Platform type and port matching** — If app registration platform is "Web", it requires exact URI match (scheme, host, port). If it's "Mobile/Desktop", it allows `http://localhost` with any port. This changes how Entra validates the redirect.

**Action items for Amos:**
1. Pull Entra app registration: `az ad app show` for exact redirect URIs (including scheme, host, port)
2. Confirm platform type: Web vs. Mobile/Desktop
3. Check if `http://127.0.0.1` is registered IN ADDITION to `http://localhost`
4. Verify Azure Web App CORS settings: `az webapp cors show` on `cloud-helper-mcp`
5. Check Entra token endpoint configuration (v1 vs v2) and conditional access policies

**User directive (APPROVED):**
- Reuse existing Foundry: `foundry-kvmorale` (Sub: hosting-ai-sandbox, RG: kvmorale_Apr-16-2026)
- **Do NOT provision new Azure AI Foundry instance**
- Investigation tests against existing foundry

**See:** `.squad/decisions.md` for full hypothesis list

