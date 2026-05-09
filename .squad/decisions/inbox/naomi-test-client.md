# Naomi — local MCP OAuth PKCE test client refresh

- **Date:** 2026-05-09T01:23:48.240-04:00
- **Status:** Proposed
- **Owner:** Naomi

## Decision

Keep a single standalone UV-managed client under `client/` that explicitly exercises the RS-mode server flow we care about now:

1. fetch `/.well-known/oauth-protected-resource`
2. fetch `/.well-known/oauth-authorization-server`
3. run loopback OAuth PKCE on `127.0.0.1`
4. exchange the code directly with Entra
5. call `/mcp` with `tools/list`

## Why

- The previous client targeted the older `/register` + `/authorize` + `/token` MCP authorization-server flow.
- The deployed FastMCP service is now RS-mode, so the local test client should validate bearer-token acquisition plus authenticated `/mcp` access instead.
- We still intentionally bind to `127.0.0.1` so the repro slot demonstrates the redirect URI mismatch and the staging slot demonstrates the fix.

## Defaults captured in client

- **repro / production slot**
  - server: `https://cloud-helper-fastmcp.azurewebsites.net`
  - client_id: `52e5e7ea-ba6a-4d66-91a3-785d2edc4d43`
  - audience: `api://cloud-helper-mcp-repro-mcp-auth-test`
- **fixed / staging slot**
  - server: `https://cloud-helper-fastmcp-staging.azurewebsites.net`
  - client_id: `7810abd8-ed7b-40f4-a447-04cc1658eab6`
  - audience: `api://cloud-helper-mcp-fixed-mcp-auth-test`

## Validation

- `cd client && uv lock`
- `cd client && uv sync`
- `cd client && uv run python -m py_compile test_client.py`
- `cd client && uv run test_client.py --help`
