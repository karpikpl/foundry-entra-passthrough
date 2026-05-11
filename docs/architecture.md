# MCP OAuth Architecture & Investigation Findings

## 1. Background — The Original Bug

The original `cloud-helper-mcp` server operated in **Authorization Server (AS) mode**, exposing `/authorize` and `/token` endpoints as an OAuth proxy to Entra ID. This design had a critical architectural flaw when used with production clients:

- **VS Code's behavior:** The `microsoft-authentication` extension intercepts any auth server matching `login.microsoftonline.com/*` and automatically bundles Microsoft Graph (`00000003`) scopes to populate the Accounts panel.
- **The rejection:** Entra rejects with `AADSTS65002` — VS Code's first-party app (`aebc6443`) is not pre-authorized for Graph in third-party tenants.
- **The impact:** This fails for **ALL users in any custom Entra tenant**. There is no workaround on the client side; the architectural mismatch is fundamental.

**Why test_client worked but VS Code didn't:**
- `test_client` uses plain PKCE without the `microsoft-authentication` extension
- VS Code and AI Foundry are **RS-mode clients** — they obtain tokens directly from Entra and inject Bearer tokens
- They never invoke the MCP server's `/token` endpoint

The production client behavior is the **correct** pattern per RFC 9728 (OAuth 2.0 Protected Resource Metadata). The original AS-mode design was fundamentally misaligned with how modern OAuth clients actually work.

## 2. App Registrations Created

Three Entra app registrations were created to support the new Resource Server (RS-mode) architecture:

| App Reg | Name | GUID | Role | Used By |
|---------|------|------|------|---------|
| `cloud-helper-mcp-repro` | Repro | N/A | Direct RS-mode (intentionally broken for VS Code) | Repro server |
| `cloud-helper-mcp-fixed` | Fixed (Server/Resource) | `7810abd8` | Defines `mcp.access` scope, validates tokens (audience) | MCP server's JWTVerifier |
| `cloud-helper-mcp-proxy` | Proxy (Client) | `b71576d8` | OAuthProxy's Entra credentials — does the OAuth dance | OAuthProxy `upstream_client_id` |

**Why two for "fixed":**
Entra's OAuth 2.0 model requires separation of concerns:
- **Resource app** (`7810abd8`): Owns the scope definition (`api://cloud-helper-mcp-fixed-mcp-auth-test/mcp.access`), validates Bearer token audiences
- **Client app** (`b71576d8`): Represents the OAuthProxy itself, holds credentials, requests scopes on behalf of other apps

This is standard OAuth 2.0 resource server + client architecture. The proxy acts as an intermediary.

## 3. The Fix: FastMCP OAuthProxy + Resource Server

### The Problem Solved
The new architecture separates concerns:
- **OAuthProxy:** Acts as a transparent proxy to Entra, advertises its own URL (not `login.microsoftonline.com`), so VS Code doesn't intercept
- **MCP Server:** Validates Bearer tokens against Entra JWKS, implements RFC 9728 PRM discovery (`/.well-known/oauth-protected-resource`)

### Key Design Points
1. **Advertise custom domain:** VS Code only intercepts `login.microsoftonline.com/*`. By advertising `https://<custom-domain>/auth/authorize`, we sidestep the Graph scope injection entirely.
2. **Plain OAuth 2.1 PKCE:** Without Graph scope injection, clients use standard token exchange.
3. **FastMCP OAuthProxy:** Exposes `/auth/authorize`, `/auth/token`, `/auth/register` on our domain; supports Dynamic Client Registration (DCR); internally proxies all tokens to Entra; issues short-lived FastMCP JWTs with embedded user claims.
4. **Token validation middleware:** MCP server uses `EntraTokenVerifier` to validate Bearer tokens, extract Entra claims, and attach them as `upstream_claims` to the FastMCP JWT.

## 4. Issues Encountered & Fixes

| Issue | Cause | Fix |
|-------|-------|-----|
| `AADSTS65001` at token exchange | OAuthProxy sent short-form `mcp.access` scope; Entra needs full `api://...` URI | `extra_token_params={"scope": full_uri}` in proxy config |
| 401 JWT audience mismatch | Entra uses GUID as `aud` in access tokens, not the `api://` URI | Added `RESOURCE_APP_ID` env var; JWTVerifier accepts both GUID and URI |
| test_client URL wrapped/unclickable | `logger.info()` wraps at terminal width | Subclassed `OAuth`, overrode `redirect_handler` to print URL between visual separators |
| test_client missing `/mcp` suffix | Wrong URL in `.env` | Fixed `.env` and `postprovision.sh` to include `/mcp` suffix |
| `hello` tool showed proxy app GUID instead of user | Tool decoded FastMCP JWT manually; FastMCP attaches `upstream_claims` at validation time | Read `access_token.claims["upstream_claims"]` directly; never manually decode |
| Re-consent on every auth | `prompt=consent` in `extra_authorize_params` | Removed — was for guest users, not needed after initial consent |

## 5. User Identity Claims (upstream_claims)

The system uses a **claims pass-through** pattern to preserve Entra user identity:

1. **At OAuthProxy token issuance:** `EntraOAuthProxy._extract_upstream_claims(idp_tokens)` is called with raw Entra tokens (access + ID token)
2. **Extraction logic:** Parses Entra ID token to extract user claims (`upn`, `email`, `family_name`, `given_name`, etc.)
3. **Embedding:** Return value stored under `upstream_claims` key in FastMCP JWT
4. **At MCP validation:** FastMCP re-attaches `upstream_claims` to `AccessToken.claims` during token validation
5. **In tool handler:** Read directly: `(access_token.claims or {}).get("upstream_claims", {})`

**Critical note:** DO NOT manually decode the FastMCP JWT in tool handlers. The `claims` dictionary is already parsed by FastMCP's validation middleware.

### Optional Claims Configuration
Optional claims were added to the fixed app manifest to ensure availability:
```bash
az ad app update --id 7810abd8 --optional-claims '{
  "accessToken": [
    {"name": "upn"},
    {"name": "email"},
    {"name": "family_name"},
    {"name": "given_name"}
  ]
}'
```

## 6. JWT Audience Notes

A subtle but critical detail about Entra access tokens:

- **Entra v2.0 access tokens always use the app GUID as `aud`, NOT the `api://` URI**
- `requestedAccessTokenVersion: 2` controls token format (v1 vs v2), but does NOT change the `aud` format
- The `api://` URI is used in the scope definition and client consent prompts, but the token itself carries the GUID

**Implementation:** `JWTVerifier` must accept both forms:
```python
jwt_audience = [resource_app_id, resolved_audience]  # Accept both GUID and URI
```

## 7. Scope Split Issue (AADSTS65001)

A surprising Entra behavior: requesting `offline_access` or `openid` alongside a custom `api://` scope causes Entra to split consent across two different Service Principals.

**Solution:** Only request the custom scope:
```
api://cloud-helper-mcp-fixed-mcp-auth-test/mcp.access
```

Omit `offline_access` and OIDC scopes (`openid`, `profile`, `email`). User claims flow through `upstream_claims` embedded in the FastMCP JWT instead.

## 8. Key Files

| File | Purpose |
|------|---------|
| `server/server.py` | Core: `EntraOAuthProxy`, `_decode_jwt_payload`, `hello` tool, `_create_mcp()` |
| `server/config.py` | `Settings` with `resource_app_id` and `jwt_audience` (list for dual-audience support) |
| `client/test_client.py` | `_OAuth` subclass for readable URL display; calls `list_tools()` then `call_tool("hello")` |
| `infra/modules/appService.bicep` | Staging slot settings include `RESOURCE_APP_ID` |
| `infra/main.bicep` | Passes `fixedAppId` to appSvc module |
| `hooks/postprovision.sh` | Generates `client/.env` with correct `/mcp` suffixed URLs |

## 9. Environment Variables (server)

| Variable | Purpose | Example |
|----------|---------|---------|
| `AZURE_CLIENT_ID` | Proxy app client ID | `b71576d8` |
| `AZURE_CLIENT_SECRET` | Proxy app secret | `<generated-secret>` |
| `RESOURCE_APP_ID` | Fixed/server app GUID | `7810abd8` |
| `AZURE_TENANT_ID` | Entra tenant ID | `<tenant-guid>` |
| `MCP_AUDIENCE` / `RESOURCE_URI` | Resource audience URI | `api://cloud-helper-mcp-fixed-mcp-auth-test` |

## 10. Architecture Diagram

```
┌─────────────────┐          ┌──────────────────────┐
│   VS Code       │          │   test_client.py     │
│   (RS-mode)     │          │   (test tool)        │
└────────┬────────┘          └──────────┬───────────┘
         │                              │
         │  1. Authorization req        │  1. Authorization req
         │  (PKCE, no Graph scopes)     │  (PKCE, no Graph scopes)
         ▼                              ▼
    ┌─────────────────────────────────────────────┐
    │   OAuthProxy (our domain)                    │
    │   /auth/authorize, /auth/token              │
    └────────┬────────────────────────────────────┘
             │  2. Proxy to Entra
             ▼
    ┌──────────────────────┐
    │  Entra ID            │
    │  (login.microsoft)   │
    └────────┬─────────────┘
             │  3. Access token + ID token (Entra issued)
             │
             │  4. FastMCP JWT (OAuthProxy issued)
             │     + upstream_claims embedded
             ▼
    ┌──────────────────────────────┐
    │   MCP Server (RS-mode)       │
    │   /mcp (Bearer validation)   │
    │                              │
    │  tools:                      │
    │  - hello (reads user claims) │
    └──────────────────────────────┘
```

## 11. Key Learnings

1. **AS-mode vs RS-mode is architectural, not just a label.** Production OAuth clients (VS Code, Foundry) expect Resource Server behavior and acquire tokens directly from the identity provider.

2. **VS Code's `microsoft-authentication` extension is opinionated.** It intercepts Microsoft URLs and injects Graph scopes automatically. Advertise a custom domain to avoid this.

3. **Entra's audience field (`aud`) uses GUID format for v2.0 tokens, not the `api://` URI.** The URI is for consent/scope definition only.

4. **Scope split in Entra is real.** Mixing OIDC scopes with custom resource scopes causes unexpected behavior.

5. **Claims pass-through via `upstream_claims` is the right pattern for multi-hop auth.** Extract at the proxy, embed in your JWT, re-expose at validation time.

6. **Manual JWT decoding in tools is a mistake.** Rely on the framework's validation middleware instead.
