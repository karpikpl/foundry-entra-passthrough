# Project Context

- **Owner:** Piotr Karpala
- **Project:** mcp-oauth — debugging and fixing an OAuth 2.0 authorization_code + PKCE flow on an MCP server (Azure Web App). After Entra login, the client never POSTs to /token — the token exchange hangs.
- **Stack:** MCP server (Azure Web App `cloud-helper-mcp`), Microsoft Entra ID, Azure AI Foundry (`foundry-kvmorale`), VS Code MCP client, OAuth 2.0 PKCE
- **Created:** 2026-05-08

## Learnings

<!-- Append new learnings below. Each entry is something lasting about the project. -->

- **2026-05-08:** The OAuth failure pattern is: Entra login completes successfully (user sees "Sign-in successful!") but the MCP client never POSTs to the server's `/token` endpoint. The connection hangs. This points to a client-side issue, not a server-side one. The server's `/token` endpoint works when tested manually.
- **2026-05-08:** Top two hypotheses: (1) Redirect URI mismatch — `http://127.0.0.1:<port>` vs `http://localhost` are NOT equivalent per RFC 8252 §8.3, and Entra may redirect to one while the client listens on the other. (2) The MCP client SDK may not implement the token exchange step at all, expecting the host app (VS Code / AI Foundry) to handle it. Both are HIGH confidence.
- **2026-05-08:** The Entra app registration platform type matters: "Mobile/Desktop" allows dynamic ports on localhost; "Web" requires exact URI match. This needs to be verified by Amos.
- **2026-05-08:** Key diagnostic: capture the browser Network tab during step 7. If the redirect to `http://127.0.0.1:<port>/` never fires (or fires but doesn't reach the client's listener), the problem is upstream of the token exchange entirely.

### 2026-05-08T17:50:48Z — CROSS-AGENT CONFIRMATION: H1 Validated by 3 Independent Sources

**H1 (HIGH) is now CONFIRMED:**
1. **Holden (Analysis):** RFC 8252 §8.3 theoretical foundation — `127.0.0.1` ≠ `localhost` for loopback OAuth redirects
2. **Naomi (Code Audit):** Confirmed in `client/test_oauth_client.py` — explicitly binds to `127.0.0.1`, sends `http://127.0.0.1:<port>/` in redirect_uri
3. **Amos (Entra Config):** Confirmed in app registration — `http://localhost` is registered, `http://127.0.0.1` is **NOT**

**This is the PRIMARY root cause of the OAuth flow hang.** Fix is ready: `az ad app update --id <APP_ID> --public-client-redirect-uris "http://localhost" "http://127.0.0.1"` (awaiting execution in "Cloud Brokers - ASC Testing" tenant by Valeria Morales).
