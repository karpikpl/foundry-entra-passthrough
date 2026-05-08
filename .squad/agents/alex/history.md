# Project Context

- **Owner:** Piotr Karpala
- **Project:** mcp-oauth — debugging and fixing an OAuth 2.0 authorization_code + PKCE flow on an MCP server (Azure Web App). After Entra login, the client never POSTs to /token — the token exchange hangs.
- **Stack:** MCP server (Azure Web App `cloud-helper-mcp`), Microsoft Entra ID, Azure AI Foundry (`foundry-kvmorale`), VS Code MCP client, OAuth 2.0 PKCE
- **Created:** 2026-05-08

## Learnings

<!-- Append new learnings below. Each entry is something lasting about the project. -->

### 2026-05-08T17:43:37Z — Test client design decisions

- **Single-file client** (`client/test_oauth_client.py`): kept all phases in one file so the flow is readable top-to-bottom without jumping across modules. Easy to paste into a bug report.
- **LoggedSession wraps requests.Session**: subclassing rather than hooks means every call — including calls inside `register_client` — is automatically logged without touching each call site.
- **`CallbackHandler.result` as class-level dict**: the HTTP server runs on a daemon thread; sharing state via a class variable avoids needing a `queue.Queue` or `threading.Event`, keeping the code minimal.
- **Port chosen dynamically with `find_free_port()`**: avoids conflicts on developer machines; the redirect_uri is constructed after port selection so registration always sends the correct URI.
- **Explicit `★` markers** at callback receipt and at the `/token` call: these are the two critical moments. If a real client logs the first marker but not the second, that's the bug proven on the wire.
- **State verification before token exchange**: catches any redirect_uri hijack or callback misparsing before we even attempt /token, keeping failure modes distinct.
- **`requests` only dependency**: stdlib handles the callback server, PKCE crypto, and browser launch — no extra installs for the test harness itself.
- **`token_endpoint_auth_method: none`** in registration payload: marks this as a public client (no client_secret), matching how AI Foundry and VS Code clients are expected to operate with PKCE.

### 2026-05-08T17:46:22Z — Cross-Agent Finding: Root cause analysis (from Holden)

**H1 (HIGH): Redirect URI mismatch** — The critical question: what exact `redirect_uri` does your test client send in the `/authorize` request? Is it `http://localhost:<port>` or `http://127.0.0.1:<port>`? This test client is specifically designed to answer that question.

**Your test client will answer:**
1. Does the client's local HTTP server actually receive the callback request (callback server logs it)?
2. What exact URI does Entra redirect to?
3. After receiving callback, does the client POST to `/token`? If yes, what response? If no, why not?

**Test scenarios to run:**
- Register with `http://localhost:<port>/` — trace what Entra redirects to
- Register with `http://127.0.0.1:<port>/` — trace what Entra redirects to
- Test with both to see which works and which fails

**Key observation:** The `★` markers you added in the test client (at callback receipt and `/token` call) are exactly the right instrumentation. If a marker appears at callback but not at `/token` call, that proves the hang happens between callback receipt and token exchange.

**See:** `.squad/decisions.md` for full hypothesis list and work plan

### 2026-05-08T17:50:48Z — CROSS-AGENT CONFIRMATION: H1 Validated by 3 Independent Sources

**H1 (HIGH) is now CONFIRMED:**
1. **Holden (Analysis):** RFC 8252 §8.3 — `127.0.0.1` ≠ `localhost`
2. **Naomi (Code Audit):** Confirmed in test client code — binds to `127.0.0.1`
3. **Amos (Entra Config):** Confirmed in app registration — `http://localhost` registered, `http://127.0.0.1` missing

This is the PRIMARY root cause. Fix command ready: `az ad app update --id <APP_ID> --public-client-redirect-uris "http://localhost" "http://127.0.0.1"` (awaiting execution in correct tenant).
