# MCP direct-Entra PKCE test client

This client validates the direct-Entra pattern end-to-end:

1. Uses a **pre-registered** public client ID (no Dynamic Client Registration)
2. Runs OAuth authorization-code + PKCE against Entra
3. Exchanges the auth code for an access token
4. Calls the MCP `/mcp` endpoint and tries `hello_world` (fallback: `hello`)
5. Prints token claims so QA can confirm `name`, `preferred_username`/`upn`, and `oid`

## How to run

```bash
cd client
uv run test_client.py direct
```

Optional overrides:

```bash
uv run test_client.py direct \
  --server-url https://example.azurewebsites.net/mcp \
  --server-client-id <server-app-id-guid> \
  --client-id <pre-registered-public-client-id>
```

Defaults:
- `--client-id` falls back to `TEST_CLIENT_ID`, then to VS Code's public client ID (`aebc6443-996d-45c2-90f0-388ff96faa56`)
- `--scope` defaults to `api://{AZURE_CLIENT_ID}/mcp.access`

## Expected result

```text
✅ Direct Entra flow succeeded: tools/list returned ...
--- Token claims ---
  name       ...
  upn        ...
  oid        ...
```

If Entra or the MCP server is misconfigured, the failure point should be obvious from the browser redirect, token exchange error, or the final MCP tool call.
