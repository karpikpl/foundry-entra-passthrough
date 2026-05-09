# MCP OAuth PKCE test client

This client reproduces the Entra loopback redirect bug for the repro slot and confirms the fix on the staging slot.

## What it tests

1. Fetches `/.well-known/oauth-protected-resource`
2. Fetches `/.well-known/oauth-authorization-server`
3. Runs OAuth authorization-code + PKCE with a local callback on `http://127.0.0.1:{random_port}`
4. Exchanges the auth code for a token
5. Calls the MCP `/mcp` endpoint with `tools/list`

The intentional `127.0.0.1` redirect is what triggers the repro app registration bug: the repro app only allows `http://localhost`, while the fixed app allows both `http://localhost` and `http://127.0.0.1`.

## How to run

```bash
cd client
uv run test_client.py repro
uv run test_client.py fixed
```

Optional overrides:

```bash
uv run test_client.py repro --client-id <app-id> --server-url https://example.azurewebsites.net
uv run test_client.py fixed --no-open-browser
```

## What to expect

### Repro

```text
❌ REPRO CONFIRMED: redirect_uri rejected by Entra
```

Typical causes:
- `redirect_uri_mismatch`
- `access_denied`
- no callback at all because Entra rejected `http://127.0.0.1:{port}` before redirecting

### Fixed

```text
✅ FIX CONFIRMED: { ... tools/list response ... }
```

That means Entra accepted the `127.0.0.1` redirect, the token exchange succeeded, and the bearer token worked against `/mcp`.
