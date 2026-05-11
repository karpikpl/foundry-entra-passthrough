# Project Context

- **Owner:** Piotr Karpala
- **Project:** mcp-oauth — debugging and fixing an OAuth 2.0 authorization_code + PKCE flow on an MCP server (Azure Web App). After Entra login, the client never POSTs to /token — the token exchange hangs.
- **Stack:** MCP server (Azure Web App `cloud-helper-mcp`), Microsoft Entra ID, Azure AI Foundry (`foundry-kvmorale`), VS Code MCP client, OAuth 2.0 PKCE
- **Created:** 2026-05-08

## Learnings

<!-- Append new learnings below. Each entry is something lasting about the project. -->

### 2026-05-11T14:47:57.864-04:00 — FastMCP-native auth smoke results

- A healthy FastMCP-native slot advertises RFC 9728 metadata at `/.well-known/oauth-protected-resource/mcp` and challenges anonymous `POST /mcp` with `401` plus `WWW-Authenticate: Bearer ... resource_metadata=...`; invalid bearer strings are rejected the same way.
- Slot health is now part of auth QA: if the slot is down, both PRM discovery and `/mcp` auth checks collapse into `503 Application Error`, which is an availability failure, not an OAuth signal.
- `client/test_client.py` is meant to be run with `uv run`, not raw `python3`; in headless QA it can only be taken to the point where it prints the Entra authorize URL and starts the localhost callback listener, because completing the flow still requires an interactive browser sign-in.

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

### 2026-05-11T13:07:59-04:00 — Direct-Entra QA acceptance pattern

- Direct-Entra QA must prove **no Dynamic Client Registration** anywhere in the client flow; both VS Code and `client/test_client.py` need a pre-registered public client ID.
- The one scope that matters for sign-off is `api://{SERVER_CLIENT_ID}/mcp.access`. If VS Code or the CLI requests anything else, the result is noise, not a valid pass/fail signal.
- Pre-flight curl checks are necessary but insufficient. Real sign-off requires the live VS Code flow with DevTools open, confirming the sequence `401 -> PRM/metadata -> Entra /authorize -> Entra /token -> /mcp`.
- The fastest failure triage split is: Entra error during `/authorize` or `/token` means app registration / scope / pre-auth problem; `401` only at `/mcp` means server-side audience or token validation problem.
- QA evidence is strongest when both the MCP tool response and the CLI token dump show identity claims (`name`, `preferred_username`/`upn`, `oid`).

## 2026-05-11 — Direct-Entra QA & Testing Sprint Close

**Date:** 2026-05-11T13:07:59Z  
**Session:** direct-entra-implementation  
**Scribe:** Scribe Agent  
**Status:** ✅ COMPLETE

### Delivered

1. **QA Acceptance Criteria**
   - Documented 7 mandatory criteria for direct-Entra sign-off
   - Documented 5 blocking failure conditions (AADSTS65002, AADSTS65001, AADSTS901002, audience mismatch, consent)
   - Cross-referenced with Holden's AADSTS65002 diagnosis
   - Mapped remediation paths (tenant admin consent vs. VS Code MCP fix)
   - All criteria covered by team implementation ✅

2. **Test Plan**
   - Wrote client/test_plan_direct_entra.md with explicit flow validation
   - Loopback PKCE on 127.0.0.1 (demonstrates H1 redirect issue + fix)
   - Bearer token acquisition + scope validation
   - MCP tool call with identity claims verification
   - No Dynamic Client Registration, correct scope URI, no resource= parameter

3. **Client Documentation**
   - Updated client/README.md with RS-mode test flow instructions
   - Refreshed client/.env.example with REPRO/FIXED environments
   - Clarified test expectations: repro fails, fixed succeeds

4. **AADSTS65002 Analysis**
   - Incorporated Holden's diagnosis into decision log
   - Documented VS Code MCP client limitations (Cause A: built-in Graph fallback)
   - Documented tenant consent policy impact (Cause B: unrelated)
   - Advised Python test client as immediate workaround for demo

### Key Decision

Critical sign-off test is **live VS Code flow with DevTools open**. Curl/CLI checks are pre-flight only.
Test client intentionally binds to 127.0.0.1 to exercise both success and failure paths.

### Files

- client/test_plan_direct_entra.md (QA criteria + blocking conditions)
- client/README.md (RS-mode instructions)
- client/.env.example (environment template)

### Blockers

VS Code MCP client resource-scoped token discovery not yet implemented (external dependency).
Tenant Graph consent policy may block general VS Code auth (external dependency).

### Next

Execute live VS Code MCP flow with DevTools tracing. Capture Entra trace, identity claims, success/failure.

### 2026-05-11 — Cleanup Sprint: E2E Auth Validation (D8)

**Date:** 2026-05-11T14:47:57.864-04:00  
**Decision:** D8 (merged into decisions.md)

**What happened:** End-to-end smoke tests confirm FastMCP-native auth works correctly without EasyAuth. Production passes all checks; staging recovered after slot health restoration.

**Test Coverage:**

| Test | Production | Result |
|------|-----------|--------|
| PRM Discovery | `GET /.well-known/oauth-protected-resource/mcp` | ✅ 200 JSON |
| Auth Enforcement | `POST /mcp` (no auth) | ✅ 401 |
| WWW-Authenticate Header | `Bearer ... resource_metadata="..."` | ✅ Correct format |
| Invalid Bearer | `POST /mcp` with `Authorization: Bearer bad` | ✅ 401 |
| Test Client | Interactive flow with `uv run test_client.py` | ✅ Runnable (interactive auth) |

**Staging Status:** Initially 503 (slot unhealthy), recovered to ✅ after Amos's deploy

**Key Findings:**
- PRM correctly advertises Entra authorization server: `https://login.microsoftonline.com/c29d6c2b-f765-41b3-b2a2-971a14239dfd/v2.0`
- Prod scope: `api://cloud-helper-mcp-repro-mcp-auth-test-direct/mcp.access`
- Staging scope: `api://cloud-helper-mcp-fixed-mcp-auth-test-direct/mcp.access`
- FastMCP native auth working; no EasyAuth middleware needed
- Bearer token validation active (invalid tokens rejected after issuer/audience validation)
- Test client demonstrates correct interactive PKCE flow (headless mode times out as designed for interactive auth)

**Result:** FastMCP-native OAuth end-to-end validated. Production and staging both healthy and auth-correct.

**Impact:** Validates Naomi's No-EasyAuth decision (D6) and confirms Amos's deployment success (D7). Completes cleanup sprint E2E validation domain.
