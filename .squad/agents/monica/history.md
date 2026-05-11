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

### 2026-05-11T13:01:36Z — Direct Entra Pattern Research (merill/mcp-entra-design)

**Task:** Synthesize concrete implementation steps from merill/mcp-entra-design for direct Entra pattern (VS Code MCP → Entra ID, no proxy).

**Sources fetched:**
1. `06-pattern-easyauth-prm.md` — Build Your Own MCP Server (EasyAuth + PRM pattern)
2. `15-auth-flow-walkthrough.md` — Complete HTTP request flow (VS Code → Entra)
3. `14-pitfalls.md` — 36 documented pitfalls with severity ranking
4. `02-mcp-auth-spec.md` — Spec evolution, RFC 9728 (PRM), RFC 8414 (ASM), RFC 8707 (resource indicators)

**Key findings:**

**Architecture:**
- MCP server = Resource Server (not Authorization Server)
- Entra ID = Authorization Server (login.microsoftonline.com)
- VS Code calls Entra directly, gets Bearer token, sends to MCP server
- PRM (Protected Resource Metadata) at `/.well-known/oauth-protected-resource` tells VS Code where to authenticate

**Entra App Registration (2-place registration for VS Code client ID):**
1. Expose scope: `api://<app-id>/user_impersonation` (delegated)
2. Add app role: `MCP.Access` (for agent identities)
3. Pre-authorize VS Code in `Expose an API > Authorized client applications` ← **Place 1**
4. Create service principal for app
5. (Optionally) Add other agents as allowed clients

**App Service Authentication (EasyAuth v2):**
1. `runtimeVersion: ~2` (v1 doesn't enforce auth properly — Pitfall #1)
2. `unauthenticatedClientAction: Return401` (MCP needs 401 + PRM pointer, not redirects)
3. Add VS Code (`aebc6443-996d-45c2-90f0-388ff96faa56`) to allowed client applications ← **Place 2**
4. Enable token store (for refresh)

**PRM Configuration (CRITICAL):**
- App setting: `WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES=api://<app-id>/user_impersonation`
- EasyAuth auto-generates PRM at `/.well-known/oauth-protected-resource`
- Endpoint is exempt from auth (clients must fetch it without token)
- Wait 5+ min after setting — propagation delay is expected (Pitfall #3)

**Token Security:**
- Validate `aud` claim matches app registration URI (Pitfall #21)
- Include Authorization header on EVERY request (Pitfall #29)
- Never forward incoming token to downstream APIs — use OBO flow (Pitfall #20)
- No tokens in query strings (Pitfall #30)

**MCP Server Code (FastAPI example):**
- FastMCP with `stateless_http=true`
- Gunicorn with `lifespan="on"` (critical — enables MCP session manager — Pitfall #19)
- Tool-level authorization in code (EasyAuth only does server-level auth — Pitfall #7)

**Scope Configuration:**
- Delegated token has `scp: "user_impersonation"` claim
- Agent identity token has `roles: ["MCP.Access"]` claim
- Always include `offline_access` in scope list for token refresh

**OAuthProxy / DCR Status (per merill):**
- OAuthProxy: NOT RECOMMENDED for direct Entra. Entra already supports PKCE, PRM, RFC 8707.
- DCR: NOT SUPPORTED by Entra (by design). Entra does not implement RFC 7591.
- CIMD (SEP-991): Recommended by new spec, but Entra doesn't support it (SSRF/trust concerns).
- **Fallback:** Pre-registration required. VS Code uses pre-registered ID `aebc6443-996d-45c2-90f0-388ff96faa56`.

**Critical Pitfall Ranking:**
- **Critical (security):** #20, #21, #22, #30 — token leakage/unauthorized access
- **High (auth fails):** #1, #2, #4, #5, #9, #12, #26, #32 — auth completely broken
- **Medium (partial failure):** #3, #7, #8, #10, #11, #13, #18, #19, #29, #33, #34, #35, #36
- **Low (dev experience):** #6, #14–17, #23–25, #27, #28, #31

**Pitfall #4 (THE 2-PLACE REGISTRATION) is critical:**
- VS Code client ID must be added in BOTH:
  1. Entra app registration (`Expose an API > Authorized client applications`)
  2. App Service (`Authentication > Allowed client applications`)
- Missing either place causes auth failure after sign-in

**Pitfall #35 (Scope mismatch):**
- `WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES` must exactly match the scope URI in Entra
- Copy character-for-character to avoid typos

**Auth Flow Summary (10 steps in VS Code):**
1. Client sends initialize (no token)
2. Server returns 401 + `WWW-Authenticate: Bearer resource_metadata="..."`
3. Client fetches PRM document (no auth needed)
4. Client discovers auth endpoints via OIDC fallback (ASM fails, expected)
5. Client opens browser → user signs in
6. Entra returns authorization code
7. Client exchanges code for token (with PKCE)
8. Client retries initialize with Bearer token
9. Server validates token (EasyAuth intercepts, validates, passes to app)
10. Connection established, tools available

**VS Code mcp.json config:**
```json
{
  "mcpServers": {
    "my-mcp-server": {
      "url": "https://my-mcp-server.azurewebsites.net/mcp",
      "auth": {
        "method": "oauth2",
        "clientId": "aebc6443-996d-45c2-90f0-388ff96faa56",
        "resource": "https://my-mcp-server.azurewebsites.net",
        "scopes": ["api://my-app-id/user_impersonation offline_access"]
      }
    }
  }
}
```

**Deliverable:** `.squad/decisions/inbox/monica-direct-entra-checklist.md` — 11-part checklist with:
- Entra app registration setup (2-place registration highlighted)
- Azure App Service EasyAuth v2 config
- PRM app setting
- VS Code mcp.json
- MCP server code (FastAPI + Gunicorn)
- OBO flow for downstream APIs
- Token security rules
- Critical pitfalls summary (Pitfall #4, #35 highlighted)
- Verification commands
- Complete setup checklist template
- Quick reference for "2 places" registration

**Sources:** merill/mcp-entra-design docs 02, 06, 14, 15; Azure App Service MCP docs; MCP spec 2025-06-18; PR #19 (FastAPI + PostgreSQL reference)

**Confidence:** HIGH — Direct Entra pattern is the recommended approach for production MCP servers. merill's documentation is authoritative and aligns with MCP spec and Azure best practices.
