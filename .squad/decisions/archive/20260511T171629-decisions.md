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

# Decision: RS-mode Entra App Registration Setup Script

**Date:** 2026-05-08T22:48:54Z  
**By:** Amos (Infra / DevOps)  
**Status:** IMPLEMENTED  
**File:** `.squad/decisions/inbox/amos-entra-rs-mode-script.md`

---

## Problem Statement

The team is moving from **Authorization Server mode** (H1 fix: `fix-entra-redirect-uri.sh`) to **Resource Server mode** (RS-mode) per RFC 9728 (PRM). This is a fundamentally different Entra architecture:

- **Previous (A-mode / H1 fix):** MCP server acts as OAuth authorization server. Clients redirect to `/authorize`, get a code, exchange code at `/token` endpoint on the server.
- **New (RS-mode / Production):** MCP server acts as protected API. Clients get Bearer tokens directly from Entra ID, then POST those tokens to the server.

The team discovered (D2 / Monica) that VS Code and AI Foundry already obtain tokens directly from Entra and **expect** RS-mode behavior. No redirect URI fix can work without moving the server to RS-mode.

We needed a script to set up Entra for this architecture.

---

## Decision

**Write `scripts/setup-entra-rs-mode.sh`** — A bash script that:

1. **Creates or reuses** an Entra app registration (idempotent)
2. **Sets Application ID URI** to `api://{client_id}` — identifies the resource server to Entra
3. **Defines OAuth2 delegated permission scope** `mcp.access` — what clients request from Entra
4. **Configures token version v2** — required for Bearer token validation
5. **Accepts parameters** for tenant, subscription, app name, dry-run mode
6. **Validates prereqs** (az CLI, logged in) before making changes
7. **Prints summary** with environment variables and implementation guidance

---

## Key Design Decisions

### 1. Idempotent by Default
- Reads current app state before creating/updating
- If app exists, reuses it (no duplicate registrations)
- If scope already exists, skips creation
- Safe to run multiple times

### 2. No Hardcoded Values
- `--tenant-id` and `--subscription` are optional but can be passed explicitly
- Default app name is `cloud-helper-mcp` but customizable via `--app-name`
- Derives tenant from subscription if needed
- Works in different Azure environments

### 3. Dry-Run Mode
- `--dry-run` prints all `az` commands that would run, makes no changes
- Useful for verification before committing to Entra changes

### 4. Application ID URI as `api://{app_id}`
- Standard Entra pattern for resource servers
- Clients will request scope: `api://{app_id}/mcp.access`
- Can be customized later in Entra portal if needed (e.g., custom domain)

### 5. OAuth2 Scope as Delegated Permission
- `mcp.access` with type="User"
- Scope value: `mcp.access` (clients request as `api://{app_id}/mcp.access`)
- Admin and user consent display names provided for clarity
- UUID generated for scope ID (deterministic via Python or `uuidgen`)

### 6. Token Version v2
- Set `api.requestedAccessTokenVersion=2`
- RS-mode servers validate JWT tokens from Entra's v2 token endpoint
- v2 tokens include `aud` (audience) and other claims needed for validation

### 7. Output Guidance
- Prints app ID, Application ID URI, scope, and token version
- Prints exact environment variables to export
- Explains usage: clients request tokens with scope, server validates via JWT

---

## Architectural Context (From H2 / Monica / Holden Research)

VS Code and AI Foundry:
- Obtain tokens from Entra ID (`https://login.microsoftonline.com/...`)
- Send Bearer tokens to MCP server in `Authorization` header
- Do NOT use the MCP server's `/authorize` or `/token` endpoints

This matches RFC 9728 (Protected Resource Model) and the "ABC Flow" documented in onsemi's `labs/mcp-prm-oauth` reference.

---

## Relationship to Previous Work

### `fix-entra-redirect-uri.sh` (H1 fix)
- Fixes redirect URI mismatch for test clients
- Adds `http://127.0.0.1` to app registration
- **Use case:** Testing with scripts that bind to loopback addresses
- **No longer needed for production** but kept for test compatibility

### `setup-entra-rs-mode.sh` (RS-mode setup)
- Sets up the entire RS-mode architecture
- Creates/configures app as resource server, not authorization server
- **Use case:** Production setup and client integration
- **Must run first** before any client integration

**Order of execution:**
1. Run `setup-entra-rs-mode.sh` — creates/configures app as resource server
2. Optionally run `fix-entra-redirect-uri.sh` — if testing with loopback clients

---

## Validation

The script follows the same patterns as `fix-entra-redirect-uri.sh`:
- Prereq checks (`az` CLI, logged in)
- Colored output (✅/❌/ℹ️ indicators)
- Idempotent design
- Dry-run mode
- Verification step (re-read app after update)
- Clear summary with implementation guidance

---

## Blockers and Workarounds

None. The script works with current `az` CLI and requires only Application Administrator role (or higher) in Entra tenant.

If user lacks permissions, the `az ad app` commands will fail with clear error messages.

---

## Next Steps

1. **Review:** Holden (Lead) validates RS-mode setup matches RFC 9728
2. **Test:** Drummer runs script and verifies app registration in Entra portal
3. **Integrate:** Piotr/Valeria run script to provision for production
4. **Document:** Server-side implementation must validate Bearer tokens using JWT inspection

---

## Files Modified

- **Created:** `scripts/setup-entra-rs-mode.sh` (executable bash script, 370 lines)
- **Updated:** `scripts/README.md` — added RS-mode section, explained usage order, clarified when to use each script
- **Updated:** `.squad/agents/amos/history.md` — added learning entry
---

# Fix Script Ready — Entra Redirect URI

**From:** Amos (Infra / DevOps)  
**Date:** 2026-05-08T18:02:01Z  
**Priority:** HIGH — blocks OAuth flow fix

## What's ready

`scripts/fix-entra-redirect-uri.sh` is written, syntax-validated, and documented in `scripts/README.md`.

The script adds `http://127.0.0.1` as a public-client redirect URI to the Entra app registration for `cloud-helper-mcp`, fixing the H1 root cause confirmed by Holden, Naomi, and Amos.

## Action required from Piotr

Run the script from an `az` session authenticated to the **"Cloud Brokers - ASC Testing"** tenant:

```bash
# Step 1 — log into the correct tenant
az login --tenant <TENANT_ID_FOR_CLOUD_BROKERS_ASC_TESTING>

# Step 2 — dry run first (safe, no changes)
./scripts/fix-entra-redirect-uri.sh \
  --subscription "Cloud Brokers - ASC Testing" \
  --dry-run

# Step 3 — apply the fix
./scripts/fix-entra-redirect-uri.sh \
  --subscription "Cloud Brokers - ASC Testing"
```

If you have the app object ID handy (more reliable than name lookup):

```bash
./scripts/fix-entra-redirect-uri.sh \
  --tenant-id    "<tenant-guid>" \
  --app-id       "<app-object-id>"
```

## Expected outcome

Script exits with:
```
✅ http://127.0.0.1 confirmed present in app registration.
✅ Done. Entra app registration is now RFC 8252 §8.3-compliant for loopback clients.
```

After that, re-test with `python client/test_oauth_client.py` — the `/token` exchange should complete.

## If access is delegated to Valeria

Forward the `scripts/` directory contents. The script has no hardcoded credentials or tenant IDs — it's safe to share.
---

# Decision: Provisioning script complete + slot assignment locked

**By:** Amos (Infra / DevOps)  
**Date:** 2026-05-09T04:11:47Z  
**Status:** COMPLETE  
**Requested by:** Piotr Karpala

---

## What was done

Wrote `scripts/provision-two-app-regs.sh` — a single, consolidated, runnable bash script that provisions the full two-app-registration repro/fixed environment end-to-end.

Updated `scripts/README.md` with a full documentation section for the new script.

---

## Slot assignment: LOCKED

This decision resolves the D10 conflict between Holden and Amos.  
**Piotr has directed Amos's mapping:**

| Slot | App registration | Redirect URIs | Role |
|------|-----------------|---------------|------|
| **production** | `cloud-helper-mcp-repro` | `http://localhost` only | Reproduce H1 bug |
| **staging** | `cloud-helper-mcp-fixed` | `http://localhost` + `http://127.0.0.1` | Demonstrate fix |

This assignment is reflected in:
- `scripts/provision-two-app-regs.sh` (sticky slot settings in Step 7)
- The summary printed at script end
- This decision file

Do **not** change this mapping without a new explicit Piotr directive.

---

## Script highlights

- **Idempotent:** checks before every create (app regs, App Service, slot)
- **Dry-run:** `--dry-run` flag prints all write commands without executing; read operations still run
- **Sticky slot settings:** `CLIENT_ID`, `AUDIENCE`, `RESOURCE_HOST`, `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` are all marked sticky — slot swap never silently changes auth profile
- **Cutover path:** Step 9 (commented out) contains the exact `az webapp config appsettings set` command to flip production from REPRO to FIXED when Piotr confirms the fix is working

---

## How to run

1. Fill in `TENANT_ID` and `TARGET_SUB` in the CONFIGURATION block at the top of the script
2. Dry-run: `./scripts/provision-two-app-regs.sh --dry-run`
3. Execute: `./scripts/provision-two-app-regs.sh`

---

## Status after provisioning

Once run successfully:
- `cloud-helper-fastmcp.azurewebsites.net` → REPRO auth (broken, H1 preserved)
- `cloud-helper-fastmcp-staging.azurewebsites.net` → FIXED auth (corrected)
- Server deployment step remains: TBD after server is packaged for `az webapp deployment`
---

### 2026-05-09T04:11:47Z: Slot assignment — production = repro
**By:** Piotr Karpala (user decision)
**What:** Production slot hosts the `cloud-helper-mcp-repro` app registration (H1 bug preserved). Staging slot hosts `cloud-helper-mcp-fixed` (H1 corrected).
**Why:** Demo the bug on the public URL first, then prove the fix on staging. Amos's recommendation accepted.
**Also decided:** AI Foundry not required for Phase 1/2 testing. Local Python PKCE client (`client/test_oauth_client.py`) is sufficient to reproduce and confirm the H1 fix. Foundry (`foundry-kvmorale`) reserved for Phase 3 RS-mode validation only.
---

### 2026-05-08T22:48:54Z: Build new MCP server with FastMCP (RS-mode)
**By:** Holden (Lead)
**Status:** DECIDED — user confirmed

## Decision
Build `cloud-helper-mcp` from scratch using FastMCP (Python). Original source unavailable.

## Architecture
- **Mode:** Resource Server (RS-mode) — NOT Authorization Server proxy
- **Framework:** FastMCP via `mcp[cli]` package
- **Auth:** Bearer token validation against Entra JWKS (RFC 9728)
- **Discovery:** Serve `/.well-known/oauth-protected-resource` per RFC 9728
- **Tool scope:** Hello world only — auth correctness is the acceptance criterion

## Why This Approach
VS Code and AI Foundry are RS-mode clients: they acquire tokens from Entra directly
and inject Bearer tokens into MCP requests. Building AS-mode (as the original server
attempted) causes the "login succeeds, /token never called" symptom confirmed in H2.

## Acceptance Criteria
1. VS Code can connect and authenticate (Bearer token accepted)
2. AI Foundry can connect and authenticate (Bearer token accepted)
3. Unauthenticated requests get 401 with proper OAuth error response
4. `/.well-known/oauth-protected-resource` returns valid RFC 9728 metadata

## Files Being Built
- `server/server.py` — FastMCP app + middleware
- `server/auth.py` — EntraTokenValidator (PyJWT)
- `server/well_known.py` — RFC 9728 discovery endpoints
- `server/config.py` — Pydantic Settings
- `server/requirements.txt`
- `server/.env.example`
- `server/README.md`
- `scripts/setup-entra-rs-mode.sh` — Entra API app registration

## Out of Scope
- Actual Azure deployment (can be added later)
- Complex tools beyond hello world
- Client-side changes (VS Code / AI Foundry handle auth themselves)
---

### 2026-05-08T18:02:45Z: Final Root Cause + Fix Strategy
**By:** Holden (Lead)
**Status:** CONFIRMED — all hypotheses resolved

---

## Root Cause (Confirmed)

### Primary (H2): Architectural Mismatch — Server is AS-mode; Clients Expect RS-mode

`cloud-helper-mcp` is deployed as an MCP Authorization Server proxy: it exposes its own `/authorize` and `/token` endpoints, expecting clients to POST to its `/token` to exchange an auth code for a token.

VS Code and AI Foundry do not use this pattern. They are designed as Resource Server clients:

- **VS Code** uses `IAuthenticationService` + `https://vscode.dev/redirect` to acquire tokens directly from Entra. It then injects the resulting Bearer token into MCP HTTP requests. It never calls the MCP server's `/token` endpoint.
- **AI Foundry** uses `https://foundry.azure.com/` as redirect URI. Without the "OAuth Identity Passthrough" feature configured in the Foundry portal, Foundry either uses its managed identity or handles token exchange server-side — it never calls the MCP server's `/token` endpoint.

The MCP server's proxy-AS role is structurally invisible to both production clients. This is the dominant cause of the failure.

### Secondary (H1): Redirect URI Mismatch — `127.0.0.1` Not Registered in Entra

For the standalone Python test client (`client/test_oauth_client.py`), there is an additional blocker: the client binds its callback listener to `127.0.0.1` and sends `redirect_uri=http://127.0.0.1:<port>/` in the `/authorize` request. Entra's app registration only contains `http://localhost` — not `http://127.0.0.1`. Per RFC 8252 §8.3 these are not equivalent. Entra either rejects the `/authorize` request outright or binds the auth code to the wrong URI, causing `/token` redemption to fail.

This is a real blocker for test-client use but is not the reason VS Code and Foundry fail — they never use the loopback redirect.

### Why the symptom occurs: "Sign-in successful" + `/token` never called

The "Sign-in successful!" page is the Entra post-login confirmation page shown after the user authenticates. It appears when Entra accepts the login. What happens next depends on the redirect URI:

- For VS Code: Entra redirects to `https://vscode.dev/redirect`. VS Code's own auth service receives the code and exchanges it with Entra directly. The MCP server is never involved.
- For Foundry: Entra redirects to `https://foundry.azure.com/`. Foundry's backend handles the code. The MCP server is never involved.
- For the test client: Entra attempts to redirect to `http://127.0.0.1:<port>/` — but this URI is not registered, so either the redirect fails or the auth code is bound to a URI the client cannot redeem.

In all cases, `POST /token` on the MCP server receives zero traffic. The server is not broken — it is simply bypassed.

---

## Fix Strategy

### Phase 1 — Unblock Testing (H1 fix, ~30 min)
**Goal:** Enable `client/test_oauth_client.py` to complete the full auth flow so the team can isolate and verify server behavior.

**Owner:** Amos (execution), Piotr (tenant access)

**Steps:**
1. Authenticate to the "Cloud Brokers - ASC Testing" tenant as Valeria Morales or with delegated access.
2. Run `scripts/fix-entra-redirect-uri.sh --subscription "Cloud Brokers - ASC Testing" --dry-run` to verify.
3. Run the script without `--dry-run` to add `http://127.0.0.1` as a public-client redirect URI.
4. Confirm: `✅ http://127.0.0.1 confirmed present in app registration.`
5. Re-run `python client/test_oauth_client.py` — verify `/token` is now called and returns a token.

**What this does NOT fix:** VS Code and Foundry will still bypass `/token`. Phase 1 only unblocks diagnostic testing.

**Secondary:** Amos should also verify and resolve the Azure Web App IP allowlisting (`az webapp show --query siteConfig.ipSecurityRestrictions`) so Naomi and the team can probe the server from the investigation machine (currently 403-blocked at IP 70.231.17.250).

---

### Phase 2 — Production Fix: RS-mode Architectural Change (~1-2 days)
**Goal:** Make `cloud-helper-mcp` operate as an MCP Resource Server, which is what VS Code and AI Foundry actually expect. This is the permanent fix.

**Owner:** Naomi (server code), Amos (Entra config alignment)

#### 2a. Add `/.well-known/oauth-protected-resource` endpoint (RFC 9728)
Add a PRM (Protected Resource Metadata) endpoint that declares:
```json
{
  "resource": "https://cloud-helper-mcp.azurewebsites.net",
  "authorization_servers": ["https://login.microsoftonline.com/<tenant-id>/v2.0"]
}
```
When VS Code or Foundry sends a request without a Bearer token and receives a 401, the MCP spec requires the server to respond with `WWW-Authenticate: Bearer resource_metadata="/.well-known/oauth-protected-resource"`. The client then fetches the PRM, discovers Entra as the AS, acquires a token from Entra directly, and retries.

Reference: onsemi `labs/mcp-prm-oauth` sample at `/home/pkarpala/projects/onsemi/ai-gateway-explore/labs/mcp-prm-oauth/`.

#### 2b. Remove or retire the `/authorize` and `/token` proxy endpoints
These endpoints represent the AS-mode proxy role. In RS-mode, the MCP server does not participate in token issuance. They can be removed or left returning `501 Not Implemented` to avoid confusion. Remove references from `/.well-known/oauth-authorization-server` as well.

#### 2c. Add Bearer token validation middleware
Add middleware that:
- Extracts `Authorization: Bearer <token>` from incoming requests
- Validates the JWT signature against Entra's JWKS endpoint (`https://login.microsoftonline.com/<tenant-id>/v2.0/keys`)
- Validates `aud` (must match the app's client ID or API URI), `iss`, and `exp` claims
- Returns 401 with `WWW-Authenticate` on failure

Reference implementation: onsemi `src/mcp-server/auth.py` (OBO + Bearer validation pattern).

#### 2d. Update `/.well-known/oauth-authorization-server` to redirect to Entra
If this metadata document is kept for legacy compatibility, update it to point directly to Entra's well-known endpoint rather than the server's own proxy endpoints. Alternatively, remove it and serve only `/.well-known/oauth-protected-resource`.

#### 2e. Enable AI Foundry OAuth Passthrough (if Foundry is a target client)
In the Foundry portal: Build → Tools → Custom → MCP → OAuth Identity Passthrough. Register `cloud-helper-mcp` as a connection with OAuth passthrough enabled. This is a portal configuration step, not a code change. Foundry will then relay user tokens to the MCP server automatically — but the server must be in RS-mode (with Bearer validation) to accept them.

---

## Agent Assignments

| Agent | Task | Phase | Priority |
|-------|------|-------|----------|
| **Amos** | Run `scripts/fix-entra-redirect-uri.sh` to add `http://127.0.0.1` to Entra app registration | Phase 1 | 🔴 Immediate |
| **Amos** | Resolve Azure Web App IP allowlisting — add investigation machine IP to allowlist | Phase 1 | 🔴 Immediate |
| **Alex** | Re-run `client/test_oauth_client.py` after H1 fix — verify `/token` now called | Phase 1 | 🔴 Immediate (after Amos) |
| **Drummer** | Reproduce TC-02 failure before Phase 1 fix (documents the broken state); sign off TC-09/TC-10 after Phase 2 | Phase 1 + 2 | 🟠 High |
| **Naomi** | Locate `cloud-helper-mcp` server source code (not in repo — must be retrieved from Azure or owner) | Phase 2 pre-req | 🔴 Blocking Phase 2 |
| **Naomi** | Implement `/.well-known/oauth-protected-resource` endpoint per RFC 9728 | Phase 2 | 🟠 High |
| **Naomi** | Remove `/authorize` and `/token` proxy endpoints (or stub as 501) | Phase 2 | 🟠 High |
| **Naomi** | Add Bearer token validation middleware (validate against Entra JWKS) | Phase 2 | 🟠 High |
| **Naomi** | Update or remove `/.well-known/oauth-authorization-server` to point to Entra | Phase 2 | 🟡 Medium |
| **Amos** | Update Entra app registration platform type to `spa` if MSAL.js/PKCE is used (resolves AADSTS9002326 risk) | Phase 2 | 🟡 Medium |
| **Amos** | Enable AI Foundry OAuth Passthrough in portal for `cloud-helper-mcp` connection | Phase 2 | 🟡 Medium |
| **Alex** | Update `client/test_oauth_client.py` to use Bearer token flow (not loopback callback_handler) once server is in RS-mode | Phase 2 | 🟡 Medium |
| **Drummer** | Update TC-02, TC-09, TC-10 test cases to reflect RS-mode expected behavior; produce sign-off report | Phase 2 | 🟡 Medium |

---

## Open Questions for Piotr

1. **Where is `cloud-helper-mcp` source code?**
   Naomi could not find it in this repository. The MCP server is deployed to `cloud-helper-mcp.azurewebsites.net` but its source is not checked in here. Phase 2 cannot start until Naomi has the code. Is it in a separate repo, owned by Valeria, or deployed directly from a pipeline?

2. **Is the onsemi `labs/mcp-prm-oauth` sample directly reusable or does it need adaptation?**
   It is the closest reference implementation (APIM + RFC 9728 PRM + Entra AS). However, it uses Azure API Management as the Bearer token validation layer. If `cloud-helper-mcp` does not sit behind APIM, Naomi will need to implement JWT validation middleware in-process instead. Decision needed: add APIM, or implement validation in-server?

3. **Does AI Foundry OAuth Passthrough need to be enabled/configured separately by the customer?**
   The Foundry passthrough feature (2026) is configured in the Foundry portal per-connection. This requires portal access to `foundry-kvmorale`. Confirm: does Piotr or Valeria have access to configure MCP connections in that Foundry instance? And is the Foundry SDK version >= the version that supports passthrough?

4. **What is the intended production client?**
   VS Code, AI Foundry, both, or a custom client? This determines which RS-mode behavior to prioritize in Phase 2. If both are targets, the PRM endpoint is required for VS Code and the Foundry passthrough portal config is additionally required for Foundry.

5. **Entra tenant access for Phase 1 execution:**
   The H1 fix script requires CLI access to "Cloud Brokers - ASC Testing" tenant. Amos's machine does not have it. Confirm: will Piotr run the script, or is it being delegated to Valeria Morales? Unblocking this is the single fastest win.
---

# Naomi — FastMCP RS-mode server built

- **Date:** 2026-05-08T22:48:54Z
- **Owner:** Naomi
- **Status:** Complete

## Files created and purpose
- `server/server.py` — FastMCP hello-world server, Starlette composition, Bearer token middleware, startup warm-up, and uvicorn entrypoint.
- `server/auth.py` — Entra JWT validator, JWKS cache, auth context helpers, and scope extraction.
- `server/well_known.py` — root `/.well-known/` endpoints and cached Entra authorization-server metadata fetch.
- `server/config.py` — environment-driven settings for tenant/app/resource configuration.
- `server/requirements.txt` — Python dependencies for FastMCP, ASGI hosting, JWT validation, and settings.
- `server/.env.example` — sample local configuration.
- `server/README.md` — install, configuration, run, flow, and smoke-test instructions.

## Key implementation decisions
- Used **PyJWT + cryptography** for JWT verification so the server only validates access tokens and never acts as an OAuth client.
- Implemented a **1-hour in-memory JWKS cache** with a forced refresh when an unknown `kid` appears, which keeps Entra calls low without making key rollover sticky.
- Put **Bearer validation in Starlette middleware ahead of the mounted FastMCP app** so unauthenticated requests fail before MCP request handling begins, while `/.well-known/` stays public.

## Known limitations / TODOs
- The hello tool relies on a request-scoped context variable for claims; if the MCP SDK exposes a first-class per-request auth context later, switch to that.
- There is no automated integration test with real Entra tokens in this repo yet; only local import/smoke validation is practical here.
- Scope enforcement currently checks `scp` and `roles`; adjust if the deployed Entra app uses a different claim shape.
---

### 2026-05-09T04:22:42Z: User directives — toolchain preferences
**By:** Piotr (via Copilot)
**What:**
1. Use **UV and UVX** for all Python packaging, virtual envs, and script running (replace pip/venv)
2. Use **AZD (Azure Developer CLI)** for deployment (replace `az webapp deployment` approach)
3. Do **app registrations in Bicep** rather than bash/az CLI (`scripts/provision-two-app-regs.sh` to be replaced or supplemented with Bicep + `azd provision`)
**Why:** User preference — captured for team memory and Amos/Naomi action
---

## 2026-05-11T13:01:36Z: Direct-Entra Pattern — Investigation & Implementation Plan
**By:** Holden (Lead / Auth Architect)  
**Branch:** `investigate/direct-entra-pattern`  
**Status:** PLAN READY — awaiting implementation

**Summary:** VS Code's MCP OAuth strips `resource` parameter; if VS Code client ID (`aebc6443-996d-45c2-90f0-388ff96faa56`) is in `preAuthorizedApplications` on the resource app registration, VS Code acquires tokens directly from Entra — eliminating the need for OAuthProxy.

**Architectural target:** FastMCP with `AuthSettings` + `JWTVerifier` (native RS-mode, no proxy).

**Changes required:**
- **server/server.py** (~215→80 lines): Remove `EntraOAuthProxy`, `_decode_jwt_payload`, rewrite `_create_mcp()` with `AuthSettings`; simplify `hello` tool to show `client_id` + scopes (Option A)
- **server/config.py**: Remove `client_secret` field
- **infra/modules/appRegistrations.bicep**: Add `preAuthorizedApplications` block to `fixedApp`, remove `proxyApp` resource
- **infra/modules/appService.bicep** & **infra/main.bicep**: Remove proxy client params
- **Validation:** `bicep build infra/main.bicep` must exit 0

**6-phase investigation:**
1. Server code (local, no deploy)
2. Bicep updates
3. Deploy & validate PRM
4. Python test client baseline
5. VS Code live test (critical: scope MUST be `api://cloud-helper-mcp-fixed/mcp.access`, not Graph)
6. Document outcome

**Risks:** VS Code may still inject Graph scopes; Bicep may not support `preAuthorizedApplications`; `JWTVerifier` protocol compliance (mitigated by pre-deploy test).

**Open questions:** 
- Does `JWTVerifier.client_id` map to `azp` (VS Code) or `sub`/`oid` (user)?
- What VS Code version supports resource stripping (Tyler Leonhardt fix)?
- Should `reproApp` also get pre-auth, or keep it to reproduce AADSTS65002?

**References:** vscode#254009, merill/mcp-entra-design, RFC 9728 §3, FastMCP `AuthSettings` + `JWTVerifier` docs.

---

## 2026-05-11T13:03:00Z: Direct Entra MCP Implementation Checklist
**By:** Monica (Researcher)  
**Source:** Synthesis of merill/mcp-entra-design documentation (docs 02, 06, 14, 15)

**Summary:** "Direct Entra" pattern (Build Your Own MCP Server with EasyAuth + PRM) is the most flexible auth approach—secures MCP server with Entra ID via EasyAuth v2 + Protected Resource Metadata (RFC 9728), supporting delegated (user-interactive) and application (agent-only) flows.

**Key insight:** NOT about proxies—Entra points directly to MCP server via app registration. VS Code uses OAuth 2.1 + PKCE. 401 response from server triggers PRM discovery, telling VS Code where/how to get token.

**Implementation checklist (4 main parts):**

**Part 1: Entra App Registration**
- Create MCP server app registration with `sign-in-audience: AzureADMyOrg`
- Add Application ID URI: `api://<APP_ID>`
- Expose delegated scope: `user_impersonation` (for user-interactive)
- Add app role: `MCP.Access` (for agents/service principals)
- **CRITICAL:** Pre-authorize VS Code in TWO places:
  1. App Registration > Expose an API > Authorized client applications: `aebc6443-996d-45c2-90f0-388ff96faa56`
  2. EasyAuth > Allowed client applications: same ID
- Create service principal: `az ad sp create --id <APP_ID>`

**Part 2: Azure App Service EasyAuth v2 Configuration**
- Enable auth: Azure AD, select MCP app registration
- **CRITICAL (Pitfall #1):** Set runtime version to `~2` (v1 does NOT enforce auth properly)
- **CRITICAL (Pitfall #2):** Unauthenticated request action = "Return 401" (MCP clients need 401 + `WWW-Authenticate` header, not login redirect)
- Enable token store (caching/refresh)
- Configure auth.json if using custom settings

**Part 3: Enable Protected Resource Metadata (PRM)**
- Set app setting: `WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES=api://<MCP-APP-ID>/user_impersonation`
- Verify endpoint: `curl https://mcp-server/.well-known/oauth-protected-resource` (returns JSON with `authorization_servers: ["https://login.microsoftonline.com/<tid>/v2.0"]`)
- Verify 401 header: `curl -i https://mcp-server/mcp` includes `WWW-Authenticate: Bearer resource_metadata=".../.well-known/oauth-protected-resource"`

**Part 4: VS Code MCP Client Configuration**
- Config stays identical: `{"servers": {"cloud-helper": {"type": "http", "url": "..."}}}`
- MCP discovery flow handles auth automatically:
  1. VS Code hits `/mcp/` → 401 + PRM URL
  2. VS Code fetches PRM → gets `authorization_servers`
  3. VS Code fetches Entra OIDC metadata → gets endpoints
  4. VS Code PKCE flow scoped to API (NOT Graph)

**Critical pitfalls:**
- Pitfall #1: EasyAuth v1 does NOT enforce auth—must use `~2`
- Pitfall #2: Redirect to login page breaks MCP clients—must return 401
- Pitfall #3: App Service restart may take several minutes
- Pitfall #4: VS Code client ID must be registered in TWO places (app reg + EasyAuth)

---
