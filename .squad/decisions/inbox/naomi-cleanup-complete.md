# Naomi Decision — Server cleanup and test client refresh complete

## What changed

### Server

- Removed the unused legacy `server/auth.py` module.
- Simplified `server/server.py` to keep only the active FastMCP native auth path (`RemoteAuthProvider` + `JWTVerifier` + PRM alias route).
- Simplified `server/config.py` and removed the unused `CLIENT_SECRET` setting.
- Updated `server/.env.example` and `server/README.md` to match the live direct-Entra configuration shape.
- Regenerated `server/requirements.txt` from `uv export` to keep the pip fallback file current.

### Client

- Updated `client/test_client.py` to default to the fixed staging slot: `https://cloud-helper-fastmcp-direct-staging.azurewebsites.net/mcp`.
- Added `--url` (with `--server-url` kept as an alias) so the same client can target either slot.
- Added explicit RFC 9728 protected-resource metadata discovery before auth.
- Kept the interactive browser PKCE flow, then reconnects to MCP with `BearerAuth` so the bearer-token step is explicit.
- Improved auth error messages and refreshed `client/README.md` plus `client/.env.example`.

## Decisions

1. **Delete dead auth code instead of preserving it for reference.**
   - The native FastMCP auth stack is the only active server path now.
   - Keeping `server/auth.py` would invite confusion because it no longer participates in request handling.

2. **Remove `CLIENT_SECRET` from server config.**
   - The direct-Entra resource-server pattern validates bearer tokens locally and does not exchange auth codes server-side.
   - `RESOURCE_APP_ID` remains the only optional compatibility field needed for GUID-form `aud` claims.

3. **Make PRM discovery explicit in the test client.**
   - This makes the direct-Entra flow easier to reason about and debug.
   - It also allows the client to derive the default scope from `scopes_supported` when the server publishes it.

4. **Keep both slot URLs supported, but default to the fixed slot.**
   - That matches the current demo goal while preserving the repro/fixed comparison setup.

## Verification

- `cd server && uv run python -c 'import server; print(server.app is not None)'`
- `cd client && uv run python test_client.py --help`
- Searched `server/` for `OAuthProxy`, `EasyAuth`, `CLIENT_SECRET`, and related remnants after cleanup.
- Verified `server/requirements.txt` still matches the current `uv export` output aside from generated header-path differences.
