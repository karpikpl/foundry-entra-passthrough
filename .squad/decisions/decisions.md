# mcp-oauth Decisions

## 2026-05-08T17:50:48Z: Research — AI Foundry + VS Code MCP OAuth PKCE support
**By:** Monica (Researcher)
**Requested by:** Piotr Karpala

### Question
Does AI Foundry / VS Code support the full OAuth PKCE token exchange for MCP? Who owns the /token POST?

---

### Onsemi Prior Analysis

Gandalf (gandalf-7, gandalf-8) conducted deep MCP auth research for the onsemi project. Key direct quotes and findings:

**From `/home/pkarpala/projects/onsemi/docs/research/gandalf-mcp-prm-oauth.md`:**
> "The `mcp-prm-oauth` lab is a **production-grade MCP implementation with OAuth 2.0 Protected Resource Metadata (RFC 9728)** support. It demonstrates the **full OAuth client authorization flow** for MCP in Azure."
>
> Flow: "1. MCP client (VS Code, Copilot Studio, or MCP Inspector) queries APIM for `/.well-known/oauth-protected-resource` (anonymous) ... 3. Client acquires OAuth token from Entra ID ... 4. Client calls MCP endpoint with Bearer token"

**From Gandalf-8 history (Foundry OAuth Passthrough Q3):**
> "What Foundry does: Agent Service automatically generates consent link, stores user token, injects it into MCP requests"
> "SDK configuration: NOT in SDK — configured in Foundry portal (Build > Tools > Custom > MCP > OAuth Identity Passthrough). Then referenced via `project_connection_id` in agent tool definition."

**From Legolas-4 history (Token Flow Explainer):**
> "Foundry Agent Service does NOT propagate user tokens to MCP tools [as of SDK 1.0.0b11]. `AIProjectClient` has no native `MCPToolDefinition`. MCP tools are invoked as custom function tools; Foundry returns `requires_action`. Your poll loop code owns the token for every downstream MCP/API call."
> "Future SDK warning: Future `MCPToolDefinition` in Foundry SDK will call MCP server-side using Foundry's managed identity — no user context unless MS adds explicit user-token forwarding."

**From Legolas-5 history (Token Flow Doc Fix):**
> "Added new section documenting Foundry-managed OAuth passthrough (2026 feature): configure project connection in Foundry portal, reference via `project_connection_id`, Foundry handles token relay automatically"
> "Foundry OAuth passthrough is purely server-side (as of 2026); app code does NOT need poll-loop OBO if MCP server is registered as a Foundry connection"

**From Legolas-6 history (AADSTS9002326 fix):**
> "Error fires when a browser-based SPA (MSAL.js v2+) attempts auth code + PKCE redemption against an app registration configured with the `web:` platform type. `web:` platform only supports server-side flows and implicit grant; Azure AD rejects cross-origin token redemption with it. Fix: replace `web: { redirectUris }` with `spa: { redirectUris }` in the Bicep app registration resource."

**From onsemi decisions.md (grep for oauth/pkce/token-exchange):**
> "No `oauth2PermissionGrant` exists for backend/APIM → AI Foundry (`cognitiveservices.azure.com/user_impersonation`)"
> "onsemi has gateway, backend, mcpServerApp — but NO portal/frontend app with auth code + PKCE redirect URIs"

**Key onsemi architectural finding:** The onsemi MCP architecture uses APIM + PRM (RFC 9728) — clients get tokens from Entra directly (Bearer pattern), not via auth_code + PKCE exchange through the MCP server's own /token. The MCP server is a **Resource Server**, not an Authorization Server. This is architecturally different from the intel cloud-helper-mcp server which IS acting as an Authorization Server.

---

### MCP Spec — OAuth Flow Spec

From `modelcontextprotocol/modelcontextprotocol/docs/specification/2025-03-26/basic/authorization.mdx`:

**The spec is explicit on client responsibility:**
```
C->>M: Token Request with code + code_verifier
M->>C: Access Token (+ Refresh Token)
```
The spec sequence diagram shows the **Client** sending the Token Request. The spec does not designate which specific software component (SDK vs host app) makes this call — it defines it as client behavior.

**MCP clients MUST implement:**
- OAuth 2.0 Authorization Server Metadata (RFC 8414)
- Authorization code grant with PKCE
- Dynamic Client Registration (SHOULD)
- Server Metadata Discovery (MUST follow /.well-known/oauth-authorization-server)

**Authorization is OPTIONAL.** Per the spec: "Authorization is OPTIONAL for MCP implementations."

---

### AI Foundry

**What Foundry does today (2026):** Foundry has two modes:

1. **Pre-2026 / SDK ≤1.0.0b11:** Foundry does NOT natively route user tokens to MCP tools. Custom function tools (requiring_action pattern) — the poll-loop app code must own token acquisition. Redirect URI used: **`https://foundry.azure.com/`**.

2. **2026 OAuth Passthrough feature:** When an MCP server is registered as a Foundry portal connection with "OAuth Identity Passthrough" enabled, Foundry handles token relay **server-side**. App code does not need to implement the callback_handler or /token POST directly. This is configured in portal, not SDK.

**Critical gap:** The intel MCP server is NOT registered as a Foundry portal connection with OAuth passthrough. When AI Foundry connects to `cloud-helper-mcp` without OAuth passthrough configured, Foundry either:
- Gets a token from Entra directly using its own credentials (managed identity), or
- Prompts the user for consent via `https://foundry.azure.com/` redirect

**Redirect URI:** `https://foundry.azure.com/` — this is registered. Foundry does NOT use `http://127.0.0.1:<port>/`. If Foundry completes auth, the browser redirects to `https://foundry.azure.com/`, and Foundry's own backend handles the token exchange — **not the MCP server's /token endpoint** in the PKCE-proxy sense.

**Sources:** Gandalf-8 research, Legolas-4/5 history, onsemi decisions.md.

---

### VS Code

**What VS Code does:** VS Code uses its own `IAuthenticationService` framework for MCP OAuth, NOT the MCP Python SDK's `OAuthClientProvider` with a loopback callback_handler.

**Evidence from VS Code source (`src/vs/workbench/contrib/mcp/common/mcpTypes.ts`):**
```typescript
export interface McpServerTransportHTTPOAuth {
    readonly clientId?: string;
}
export interface McpServerTransportHTTPAuthentication {
    readonly providerId: string;  // VS Code auth provider ID
    readonly scopes: string[];
}
// NOTE: authentication is @deprecated
```

VS Code's `McpServerTransportHTTP` type has an `oauth` field with only `clientId` — no redirect_uri, no callback_handler wiring. Auth integration uses `IAuthenticationService.getSessions()` / `getAccounts()` / `removeSession()` — VS Code's own provider-based auth framework.

**Redirect URI:** `https://vscode.dev/redirect` — this is VS Code's standard OAuth redirect, handled internally by VS Code's auth service infrastructure. VS Code does NOT open `http://127.0.0.1:<port>/` as a callback server.

**What VS Code actually does for MCP HTTP auth:**
1. VS Code detects 401 from MCP server
2. VS Code uses `IAuthenticationService` to acquire a token (via its Microsoft auth provider)
3. Token is acquired via VS Code's own OAuth flow with `https://vscode.dev/redirect`
4. VS Code injects the Bearer token into subsequent MCP HTTP requests
5. VS Code does **NOT** POST to the MCP server's `/token` endpoint — it bypasses the MCP server's AS role entirely and uses Entra tokens directly

**Sources:** VS Code `mcpTypes.ts`, `mcpServerActions.ts`, `mcpCommands.ts`, `mcpServer.ts` (line 694: `UserInteractionRequiredError('auth')`).

---

### MCP SDK

**Python SDK (`modelcontextprotocol/python-sdk`) — auth IS implemented:**

The Python SDK includes a full `OAuthClientProvider` (`src/mcp/client/auth/oauth2.py`) that implements the complete auth_code + PKCE flow. Key structure:
- `PKCEParameters.generate()` — generates code_verifier + code_challenge
- `_perform_authorization_code_grant()` — calls `redirect_handler` to open browser, then `callback_handler` to receive the code
- `_exchange_token_authorization_code()` — POSTs to `/token` with `grant_type=authorization_code`, `code`, `code_verifier`, `redirect_uri`

**BUT:** The SDK requires the calling application to provide:
- `redirect_handler: Callable[[str], Awaitable[None]]` — opens browser
- `callback_handler: Callable[[], Awaitable[tuple[str, str | None]]]` — starts a local HTTP server and waits for the browser redirect to come back with the auth code

If `callback_handler` is not provided, or provided but hangs (no one listening on the redirect URI), **the token exchange never fires**.

**Active GitHub issues (confirmed open):**
- `#2208`: `get_access_token()` returns stale token in stateful streamable-HTTP sessions
- `#2121`: `OAuthClientProvider` requires unnecessary round-trip — no way to pre-configure auth server URL
- `#2078`: Restore eager OAuth discovery to avoid slow unauthenticated roundtrip
- `#2193`: Add Authlib-backed OAuth adapter
- `#2100`: Bind authenticated identity to sessions in StreamableHTTPSessionManager

None of the open issues are specifically "token exchange never fires" as a SDK bug. The token exchange failure is most likely an application-level issue (callback_handler never receives the code).

**TypeScript SDK:** Has OAuth helpers for clients, but VS Code does not use the TS SDK's OAuthClientProvider — VS Code uses its own `IAuthenticationService`.

---

### Verdict

#### Q1: Does AI Foundry support full OAuth PKCE for MCP?
**Partially.** Foundry's 2026 OAuth Passthrough feature supports it when the MCP server is registered in the Foundry portal with "OAuth Identity Passthrough" enabled. Without that configuration (as is the case with `cloud-helper-mcp`), Foundry does NOT call the MCP server's `/token` endpoint. Foundry uses `https://foundry.azure.com/` as redirect URI and handles token exchange through its own backend. **The MCP server's /token is never called by Foundry unless OAuth passthrough is configured.**

#### Q2: Does VS Code support full OAuth PKCE for MCP?
**Partially.** VS Code supports OAuth for MCP HTTP servers but uses its own `IAuthenticationService` framework, NOT a loopback redirect to `http://127.0.0.1:<port>/`. VS Code uses `https://vscode.dev/redirect` and handles token exchange through its own Microsoft auth provider. **VS Code does NOT POST to the MCP server's /token endpoint — it acquires Entra tokens directly and injects them as Bearer tokens.**

#### Q3: Who is responsible for the /token POST in the MCP client architecture?
**The MCP SDK's `OAuthClientProvider` owns the /token POST** — but only when the calling application (host app) wires up the `callback_handler` correctly (i.e., starts a local HTTP server on the redirect URI and waits for the browser redirect). For VS Code and AI Foundry, the host app uses a different mechanism (VS Code's `IAuthenticationService`, Foundry's OAuth passthrough) that does NOT call the MCP server's /token endpoint.

#### Q4: Is there a known issue or limitation with the MCP client not completing token exchange?
**Yes — architectural mismatch, not a SDK bug.** The intel MCP server is designed as an MCP Authorization Server (it proxies /authorize to Entra and provides its own /token). But VS Code and Foundry are designed as Resource Server clients — they get tokens from Entra directly and present them as Bearer tokens. They never call the MCP server's /token. There is no SDK bug per se; this is an architectural mismatch between what the MCP server provides and what VS Code/Foundry expect.

#### Q5: What does the onsemi prior analysis tell us?
**Critical:** The onsemi analysis (Gandalf-7/8, Legolas-4/5) establishes that the working MCP auth pattern uses **APIM + PRM (RFC 9728)**:
- MCP server = Resource Server (validates Bearer tokens)
- Entra = Authorization Server (issues tokens)
- Client (VS Code, Foundry) gets token from Entra → presents to MCP server
- The MCP server's /token endpoint is NOT in this flow

The intel `cloud-helper-mcp` inverts this: it acts as both proxy-AS and RS, expecting clients to POST to its /token. VS Code/Foundry are not designed for this pattern.

#### Q6: Working samples for full OAuth PKCE flow with Entra/Azure?
**Yes, but with APIM+PRM architecture:**
- `labs/mcp-prm-oauth` in onsemi (from `azure-samples/AI-Gateway`) — uses APIM + RFC 9728 PRM, not AS-mode MCP server
- MCP Python SDK `examples/snippets/clients/oauth_client.py` — shows the full loopback redirect flow (requires a custom application providing `callback_handler`)
- No published sample of a standalone MCP server acting as AS with VS Code/Foundry as client using `http://127.0.0.1` redirect

---

### Implications for Holden's H2

**H2 is CONFIRMED with important nuance.**

The MCP Python SDK DOES implement token exchange (`OAuthClientProvider._exchange_token_authorization_code()`). So the SDK itself is not broken.

However, H2 is confirmed in the following sense: **VS Code and AI Foundry do NOT invoke the MCP server's /token endpoint.** They use their own auth frameworks (`IAuthenticationService` for VS Code, OAuth passthrough for Foundry) that bypass the MCP server's AS role. The clients present Bearer tokens issued directly by Entra — they never use the proxy-AS pattern.

**The combination of H1 + H2 explains the full failure:**
- **H1 (redirect URI mismatch):** Alex's test client sends `redirect_uri=http://127.0.0.1:<port>/` but Entra only has `http://localhost` registered → auth request fails or redirect is rejected
- **H2 (client doesn't use /token):** Even if H1 is fixed, VS Code and Foundry will still never call the MCP server's /token because they bypass it architecturally

**Architectural recommendation:** The intel MCP server should switch from AS-mode to RS-mode:
1. Remove the proxy /authorize and /token endpoints
2. Add `/.well-known/oauth-protected-resource` (RFC 9728 PRM) pointing to Entra as AS
3. Validate incoming Bearer tokens (issued by Entra) using APIM JWT validation or middleware
4. This matches the pattern VS Code and Foundry actually implement

---

### Working Samples Found

| Sample | Location | Auth Pattern | Relevant? |
|--------|----------|--------------|-----------|
| `labs/mcp-prm-oauth` | `/home/pkarpala/projects/onsemi/ai-gateway-explore/labs/mcp-prm-oauth/` | APIM + RFC 9728 PRM, Entra AS | ✅ High — correct architecture for VS Code/Foundry |
| MCP Python SDK `oauth_client.py` | `modelcontextprotocol/python-sdk/examples/snippets/clients/` | Loopback redirect, custom callback_handler | ⚠️ Medium — requires custom app, not VS Code/Foundry |
| onsemi `src/mcp-server/auth.py` | `/home/pkarpala/projects/onsemi/src/mcp-server/auth.py` | OBO + Bearer validation | ✅ High — RS-mode MCP server with Entra auth |
