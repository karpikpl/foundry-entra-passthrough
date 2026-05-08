# Squad Decisions

## Investigation Round 1 — OAuth Token Exchange Failure (2026-05-08)

### D1: Root Cause Analysis — OAuth token exchange failure
**By:** Holden (Lead / Auth Architect)  
**Date:** 2026-05-08T17:43:37Z  
**Status:** Investigation pending — H1 and H2 are highest priority

**Summary:** Most likely root cause is redirect URI mismatch between `http://127.0.0.1:<port>/` (what Entra actually redirects to) and `http://localhost` (what is registered), or the MCP client SDK may not implement token exchange.

**Seven ranked hypotheses:**
- **H1 (HIGH):** Redirect URI mismatch — `127.0.0.1` vs `localhost`
- **H2 (HIGH):** MCP client SDK does not perform token exchange
- **H3 (MEDIUM):** Client callback handler fails on state/PKCE validation
- **H4 (MEDIUM):** Entra "Sign-in successful!" page is dead end
- **H5 (MEDIUM):** Port-specific redirect URI rejected by Entra
- **H6 (LOW):** CORS blocks `/token` POST
- **H7 (LOW):** Authorization code expired or single-use collision

**Investigation assigned to:**
- **Naomi:** Server-side verification (metadata, `/authorize`, CORS, `/token` logging)
- **Amos:** Entra & Azure verification (app registration, platform type, CORS, token endpoint)
- **Alex:** Client-side tracing (build test client, HTTP trace capture, SDK inspection)
- **Drummer:** Reproduction and exact failure point documentation

---

### D2: OAuth test suite created
**By:** Drummer (Tester / QA)  
**Date:** 2026-05-08T17:43:37Z  
**File:** tests/oauth-flow-test-cases.md

12 test cases covering:
- OAuth PKCE happy path
- Known failure (TC-02) — must reproduce before fix
- Edge cases
- **Blocking:** TC-09 and TC-10 must pass before sign-off

---

### D3: Minimal OAuth test client created
**By:** Alex (MCP Client Dev)  
**Date:** 2026-05-08T17:43:37Z  
**Files:** client/test_oauth_client.py, client/requirements.txt, client/README.md

Python test client that:
- Exercises full OAuth PKCE flow with verbose HTTP logging
- Starts local callback server
- Explicitly logs whether `/token` is called
- Will show exact point of hang

---

### D4: User directive — reuse existing Foundry
**By:** Piotr Karpala (via Copilot)  
**Date:** 2026-05-08T17:46:22Z  
**Status:** APPROVED

- **No new Azure AI Foundry provisioning**
- Reuse existing foundry: `foundry-kvmorale` (Sub: hosting-ai-sandbox, RG: `kvmorale_Apr-16-2026`)
- **Impact:** Amos should NOT provision new instance. Investigation tests against existing foundry.

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
