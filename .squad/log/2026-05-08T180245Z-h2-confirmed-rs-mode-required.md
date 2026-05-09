# Session 2026-05-08T18:02:45Z — H2 Confirmed: RS-Mode Architectural Fix Required (RFC 9728)

**Session Date:** 2026-05-08  
**Decision:** H2 (MCP clients don't call /token) is now CONFIRMED; RS-mode architectural fix identified  
**Status:** Ready for architectural redesign; execution blocked by code ownership

## Executive Summary

H2 is confirmed: **VS Code and AI Foundry do NOT invoke the MCP server's /token endpoint.** They use their own OAuth frameworks that obtain Bearer tokens directly from Entra ID and bypass the MCP server's Authorization Server role entirely.

This explains why the proxy-AS pattern (redirect to Entra, MCP server issues token) never works with production clients. The solution is an architectural shift from AS-mode to RS-mode (Resource Server), validated by the onsemi reference implementation using RFC 9728 Protected Resource Metadata.

## Cross-Agent Confirmation

| Agent | Finding | Confidence | Evidence |
|-------|---------|------------|----------|
| **Holden** (Lead) | H1 + H2 both HIGH; AS-to-RS architectural shift required | HIGH | Theory + standards analysis |
| **Naomi** (Code Audit) | H1 confirmed (127.0.0.1 vs localhost binding) | HIGH | test_oauth_client.py inspection |
| **Amos** (Entra Config) | H1 confirmed (only http://localhost registered) | HIGH | Entra app registration audit |
| **Monica** (Researcher) | H2 confirmed (VS Code + Foundry use different frameworks) | HIGH | VS Code source, Foundry docs, MCP spec, onsemi prior |

## Key Findings

### H1: Redirect URI Mismatch (CONFIRMED by Naomi, Amos)
- Client sends `redirect_uri=http://127.0.0.1:<port>/`
- Entra has only `http://localhost` registered
- RFC 8252 §8.3: `127.0.0.1` and `localhost` are distinct addresses
- **Fix:** Add `http://127.0.0.1` to Entra app registration (ready, awaiting execution)

### H2: Clients Don't Use /token (CONFIRMED by Monica)

**VS Code:**
- Uses `IAuthenticationService` (internal auth framework)
- Redirect URI: `https://vscode.dev/redirect` (handled by VS Code's auth service)
- Does NOT open `http://127.0.0.1:<port>/` callback server
- Does NOT POST to MCP server's `/token` endpoint
- Instead: Acquires Entra token directly, injects as Bearer token in MCP requests

**AI Foundry:**
- Pre-2026 SDK: Custom function tools (requires_action) — app owns token acquisition, uses `https://foundry.azure.com/` redirect
- 2026 OAuth Passthrough: Server-side token relay configured in Foundry portal (NOT SDK)
- Does NOT POST to MCP server's `/token` endpoint
- Instead: Acquires Entra token via Foundry backend, injects as Bearer token in MCP requests

**MCP Python SDK:**
- DOES implement full token exchange (`OAuthClientProvider._exchange_token_authorization_code()`)
- Requires calling app to provide `callback_handler` (local HTTP server on redirect URI)
- No standalone sample of MCP server acting as AS with VS Code/Foundry as clients

### Architectural Mismatch

| Component | Current (intel cloud-helper-mcp) | Correct (onsemi reference) |
|-----------|----------------------------------|--------------------------|
| **MCP Server Role** | Authorization Server (AS) | Resource Server (RS) |
| **/authorize endpoint** | Proxy to Entra | N/A |
| **/token endpoint** | Issue tokens | N/A |
| **Client behavior** | POST to /token (expected but never happens) | GET Bearer token from Entra, present to RS |
| **Token validation** | N/A | JWT validation at /authorize request or via middleware |
| **Reference** | intel pattern (broken with VS Code/Foundry) | onsemi `labs/mcp-prm-oauth` + RFC 9728 PRM |

## Recommended Fix: RS-Mode Switch

**Current state (AS-mode):** MCP server tries to issue tokens → clients never call /token → auth fails

**Target state (RS-mode):**
1. Remove proxy `/authorize` endpoint
2. Remove `/token` endpoint
3. Add `/.well-known/oauth-protected-resource` (RFC 9728 Protected Resource Metadata)
   - Point to Entra as Authorization Server (`https://login.microsoftonline.com/{tenantId}/oauth2/v2.0`)
4. Validate incoming Bearer tokens using JWT validation (APIM or middleware)
5. Clients (VS Code, Foundry) automatically use this metadata to route tokens through Entra

**Why this works:**
- VS Code + Foundry already expect this pattern (query `/.well-known/oauth-protected-resource`, get token from Entra, present to MCP)
- onsemi has production-grade reference implementation
- RFC 9728 is standardized and implemented by all MCP clients

## Secondary Finding: IP Allowlisting

Azure Web App returns `403 Ip Forbidden` (external IP: 70.231.17.250). Blocks testing but not the root cause of OAuth failure.

## Cross-Agent Consensus

All agents converge on H1 + H2:
- **H1 (redirect URI mismatch) is fixable immediately** with `az ad app update`
- **H2 (architectural mismatch) requires redesign** but is now validated

## Next Steps

1. ✅ H2 confirmed and decision documented
2. ⏳ Execute H1 fix (Valeria: add `http://127.0.0.1` to Entra registration)
3. ⏳ Implement RS-mode architectural switch (code owner: TBD)
   - Reference: onsemi `labs/mcp-prm-oauth` (APIM + JWT validation pattern)
   - Reference: RFC 9728 Protected Resource Metadata spec
4. ⏳ Re-test with VS Code and AI Foundry after RS-mode deployment
