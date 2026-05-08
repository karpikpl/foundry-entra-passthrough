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

### 2026-05-08T17:46:22Z: Entra config audit completed — redirect URI mismatch confirmed as root cause

**Source:** `issue.md` + `issue-report.md` (customer-documented URIs) + `client/test_oauth_client.py` (client behavior)

- The Entra app registration for `cloud-helper-mcp` has **`http://localhost`** registered (with implied "any port" / Mobile and desktop applications platform). `http://127.0.0.1` is **NOT registered**.
- The test client and all MCP clients bind their callback listener to `127.0.0.1` and send `http://127.0.0.1:<port>/` as `redirect_uri` in `/authorize`. This URI is not in the Entra registration.
- Per RFC 8252 §8.3 and Entra's matching rules, `localhost` and `127.0.0.1` are **distinct** — dynamic-port allowance on `http://localhost` does not extend to `http://127.0.0.1`.
- **H1 (HIGH)** is confirmed as the primary root cause. **H5** may be a secondary issue depending on platform type (Web vs. Mobile/Desktop) — needs direct CLI verification.
- **CORS (H6):** Could not verify — `rg-cloud-helper-mcp` is not accessible from current CLI context. Manual check required.

**Fix:** Add `http://127.0.0.1` to the "Mobile and desktop applications" platform redirect URIs in the Entra app registration:
```bash
az ad app update --id <APP_ID> --public-client-redirect-uris "http://localhost" "http://127.0.0.1"
```

**CLI blocker:** "Cloud Brokers - ASC Testing" subscription is in a different tenant, not accessible from current `az` session. All remediation commands must be run by the subscription owner (Valeria Morales / Intel team). Full command set documented in `.squad/decisions/inbox/amos-entra-config-audit.md`.

### 2026-05-08T17:50:48Z — CROSS-AGENT CONFIRMATION: H1 Validated by 3 Independent Sources

**H1 (HIGH) is now CONFIRMED:**
1. **Holden (Analysis):** RFC 8252 §8.3 — `127.0.0.1` ≠ `localhost`
2. **Naomi (Code Audit):** Confirmed in `client/test_oauth_client.py` — binds to `127.0.0.1`
3. **Amos (Entra Config):** Confirmed in app registration — `http://localhost` registered, `http://127.0.0.1` missing

**Secondary finding (IP Allowlisting from Naomi):**
- Azure Web App blocks external IPs (70.231.17.250 returns 403)
- Not the cause of OAuth hang but should be addressed for diagnostic access

**Fix command ready:** `az ad app update --id <APP_ID> --public-client-redirect-uris "http://localhost" "http://127.0.0.1"`  
**Execution status:** Awaiting execution in "Cloud Brokers - ASC Testing" tenant
