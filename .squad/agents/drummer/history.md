# Project Context

- **Owner:** Piotr Karpala
- **Project:** mcp-oauth — debugging and fixing an OAuth 2.0 authorization_code + PKCE flow on an MCP server (Azure Web App). After Entra login, the client never POSTs to /token — the token exchange hangs.
- **Stack:** MCP server (Azure Web App `cloud-helper-mcp`), Microsoft Entra ID, Azure AI Foundry (`foundry-kvmorale`), VS Code MCP client, OAuth 2.0 PKCE
- **Created:** 2026-05-08

## Learnings

<!-- Append new learnings below. Each entry is something lasting about the project. -->

### 2026-05-08T17:43:37Z — OAuth PKCE test suite written

**12 test cases written** in `tests/oauth-flow-test-cases.md`.

**What I'm watching for:**

- **TC-02 is the blocker.** The bug: after Entra login, the client receives the auth code at the callback URI (`http://127.0.0.1:<port>/`) but never calls `/token`. The prime suspect is a redirect URI mismatch — the server/Entra have `http://localhost` registered, but clients actually get redirected to `http://127.0.0.1:<port>/`. Clients may silently drop a callback that doesn't match what they registered, and `/token` is never called as a result.

- **TC-11 is a canary.** If `/.well-known/oauth-authorization-server` advertises `redirect_uris` that don't match what Entra has registered, or don't match what VS Code / AI Foundry actually send, that's the root cause. Run TC-11 first — it's cheap and may immediately confirm the hypothesis.

- **TC-03 and TC-04 are security gates.** The fix must not weaken redirect URI validation or PKCE enforcement. If the fix involves relaxing URI matching (e.g., treating `localhost` and `127.0.0.1` as equivalent), it must be done server-side with explicit allow-list logic, not by disabling validation.

- **TC-09 and TC-10 are the acceptance bar.** No sign-off until both real clients (VS Code and AI Foundry) connect successfully end-to-end. Manual curl tests are necessary but not sufficient.

### 2026-05-08T17:50:48Z — CROSS-AGENT CONFIRMATION: H1 Validated by 3 Independent Sources

**H1 (HIGH) is now CONFIRMED:**
1. **Holden (Analysis):** RFC 8252 §8.3 — `127.0.0.1` ≠ `localhost`
2. **Naomi (Code Audit):** Confirmed in test client — binds to `127.0.0.1`
3. **Amos (Entra Config):** Confirmed in app registration — `http://localhost` registered, `http://127.0.0.1` missing

**This is the PRIMARY root cause of the OAuth flow hang.** Fix command is ready; awaiting execution in correct Azure tenant. TC-02 should pass after fix is applied.
