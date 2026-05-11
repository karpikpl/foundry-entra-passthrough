# Session Log: Direct-Entra Investigation

**Date:** 2026-05-11  
**Time:** 13:01:36 UTC−4  
**Session Type:** Research + Planning Sprint  
**Team:** Holden (Lead, Auth Architect) + Monica (Researcher) + Scribe (Documentation)

---

## Objective

Investigate whether the "direct-Entra" pattern (VS Code → Entra, no proxy) is viable for the mcp-oauth project, and if so, produce a complete implementation specification.

---

## Background Context

### Problem Statement

Current architecture uses `OAuthProxy` as a middleman between VS Code and Entra, because:
- VS Code's built-in Microsoft authentication provider injects Graph scopes (`00000003`)
- Entra's third-party tenant rejects Graph scope injection → `AADSTS65002`
- Proxy advertises a non-Microsoft auth server URL, forcing VS Code to use plain OAuth 2.1 PKCE

This adds operational overhead: manage proxy credentials, maintain proxy code, proxy authentication logic.

### Evidence for Change

From vscode#254009 (Tyler Leonhardt): "VS Code's MCP OAuth implementation strips the `resource` parameter before forwarding to Entra."

From merill/mcp-entra-design: "2 places" pre-authorization pattern enables seamless (zero-consent) access for VS Code if client ID is registered correctly.

### Hypothesis

If VS Code's client ID (`aebc6443-996d-45c2-90f0-388ff96faa56`) is in the resource app's `preAuthorizedApplications`, VS Code can:
1. Use Entra's `/authorize` endpoint directly
2. Complete PKCE flow to acquire token scoped to our API
3. Call FastMCP's `/mcp` endpoint with Bearer token

**Result:** Zero proxy, cleaner architecture, fewer credentials.

---

## Investigation Findings

### 1. Holden's Analysis: Server-Side Implementation

**Scope:** What changes to FastMCP code + Bicep infrastructure are needed?

**Output:** `holden-direct-entra-plan.md` — 299 lines

**Key decisions:**
- Remove ~70 lines of OAuthProxy + helper code from `server.py`
- Replace with ~15 lines: `AuthSettings` + `JWTVerifier`
- Simplify `hello` tool: show `client_id` + scopes (Option A, not full claims)
- Remove `client_secret` from `config.py`
- Add `preAuthorizedApplications` to Bicep `fixedApp`
- Remove `proxyApp` resource from Bicep entirely

**Validation step:** 6-phase investigation protocol captures all necessary tests (local server startup through VS Code live test with DevTools inspection).

**Risk:** Medium — VS Code may still inject Graph scopes despite pre-auth. Branch is isolated; fallback is main branch (status quo).

### 2. Monica's Analysis: Entra + App Service Configuration

**Scope:** How to configure Entra and Azure App Service to enable PRM + preAuthorizedApplications?

**Output:** `monica-direct-entra-checklist.md` — 330 lines

**Key decisions:**
- 4-part implementation: app registration, EasyAuth v2, PRM, client config
- "2 places" pre-auth pattern (app registration + EasyAuth)
- Critical pitfalls: EasyAuth v1 insufficient, 401 (not redirect) required, restart delay, client registration locations
- Validation: PRM endpoint check, 401 header inspection

**Audience:** Amos (infrastructure engineer) or Naomi (deployment engineer).

**Dependency:** Holden's Phase 2 (Bicep) + Phase 3 (deploy) should reference Monica's checklist.

---

## Decision Log (from .squad/decisions/ merge)

Both plans were merged into `.squad/decisions/decisions.md`:

1. **2026-05-11T13:01:36Z**: Holden's direct-Entra implementation plan (299 lines condensed into 67-line summary + phase list)
2. **2026-05-11T13:03:00Z**: Monica's direct-Entra checklist (330 lines condensed into 82-line summary + 4-part checklist)

Both entries reference each other and the 6-phase investigation protocol.

---

## Next Steps

### Immediate (Week 1)

1. **Code Review:** Holden's plan by Piotr (user), consensus from Amos/Naomi
2. **Feasibility Check:** Monica's checklist by Amos (infrastructure), confirm Bicep syntax, EasyAuth version support
3. **Branch Setup:** Create `investigate/direct-entra-pattern` if not already present

### Phase 1 (Week 2)

Whoever is assigned Phase 1 (server code refactor):
- Strip OAuthProxy + helpers from `server.py`
- Rewrite `_create_mcp()` with `AuthSettings`
- Simplify `hello` tool (Option A)
- Remove `client_secret` from `config.py`
- Local test: `uvicorn server:app --port 8000`
- Verify `/.well-known/oauth-protected-resource/mcp` returns correct PRM JSON

### Phase 2 (Week 2)

Whoever is assigned Phase 2 (Bicep refactor):
- Reference Monica's Part 1 checklist
- Add `preAuthorizedApplications` to `fixedApp`
- Remove `proxyApp` resource block
- Remove proxy client params from `appService.bicep`, `main.bicep`
- Run `bicep build infra/main.bicep` → must exit 0

### Phase 3–5 (Week 3)

Deployment and VS Code live test (the critical experiment).

### Phase 6 (Week 3)

Document findings in `docs/architecture.md` + update decisions.

---

## Team Context

- **Holden (Lead, Auth Architect):** Analyzing architecture, specifying code changes, owning hypothesis validation
- **Monica (Researcher):** Synthesizing Entra/Azure best practices from merill source materials, producing actionable checklist
- **Scribe (Documentation):** Logging session, maintaining decisions registry, coordinating handoff

---

## Files Modified

- `.squad/decisions/decisions.md`: +147 lines (2 new decisions merged, inbox files removed)
- `.squad/orchestration-log/2026-05-11T13-01-36-holden.md`: +NEW
- `.squad/orchestration-log/2026-05-11T13-03-00-monica.md`: +NEW
- `.squad/log/2026-05-11T13-01-36-direct-entra-investigation.md`: +NEW (this file)
- `.squad/decisions/inbox/{holden-direct-entra-plan.md, monica-direct-entra-checklist.md}`: DELETED

---

## References

- [vscode#254009](https://github.com/microsoft/vscode/issues/254009) — Tyler Leonhardt confirms resource param stripping
- merill/mcp-entra-design (docs 02, 06, 14, 15) — pre-auth + EasyAuth pattern
- RFC 9728 — Protected Resource Metadata (PRM)
- FastMCP docs — `AuthSettings`, `JWTVerifier`, native RS-mode
- Current codebase: `server/server.py` (~215 lines), `infra/modules/appRegistrations.bicep`, `infra/modules/appService.bicep`

---
