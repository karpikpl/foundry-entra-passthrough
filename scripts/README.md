# scripts/

Operational scripts for the mcp-oauth project.

---

## provision-two-app-regs.sh

### What it does

End-to-end provisioning of the two-app-registration repro/fixed environment.
Run this once to bring the full infrastructure to the correct state.

**Slot assignment (locked):**
| Slot | App registration | Redirect URIs | Purpose |
|------|-----------------|---------------|---------|
| production | `cloud-helper-mcp-repro` | `http://localhost` only | Reproduce H1 bug |
| staging | `cloud-helper-mcp-fixed` | `http://localhost` + `http://127.0.0.1` | Demonstrate the fix |

**What it creates / configures:**

1. **Entra app reg `cloud-helper-mcp-repro`** — RS-mode, `api://<id>/mcp.access` scope, public-client redirect URI = `http://localhost` **only** (preserves H1 bug)
2. **Entra app reg `cloud-helper-mcp-fixed`** — RS-mode, same scope, adds `http://127.0.0.1` (fixes H1)
3. **New App Service `cloud-helper-fastmcp`** — reuses the existing plan from `cloud-helper-mcp`; no inherited IP restrictions
4. **Staging slot** on `cloud-helper-fastmcp`
5. **Shared app settings** (`TENANT_ID`, `PORT=8000`, `SCM_DO_BUILD_DURING_DEPLOYMENT=true`) on both slots
6. **Sticky slot settings** (`CLIENT_ID`, `AUDIENCE`, `RESOURCE_HOST`, `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`) wired to the correct app reg per slot
7. **Commented-out cutover command** (Step 9) — ready to flip production to the fixed app reg when validated

The script is **idempotent** — safe to run multiple times. It checks before creating every resource.

### Prerequisites

- **Azure CLI** (`az`) — https://docs.microsoft.com/cli/azure/install-azure-cli
- **jq** — https://stedolan.github.io/jq/
- **python3** — used to generate UUIDs for scope IDs
- **Logged in** to the Entra tenant that owns `TARGET_SUB`:
  ```bash
  az login --tenant <TENANT_ID>
  ```
- **Application Administrator** or higher on that Entra tenant (to create/update app registrations)
- **Contributor** or higher on the `TARGET_SUB` subscription (to create the App Service)

### Usage

**Step 1 — Fill in the CONFIGURATION block** at the top of the script:

```bash
TENANT_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"   # Entra tenant GUID
TARGET_SUB="Cloud Brokers - ASC Testing"            # subscription name or ID
```

**Step 2 — Dry-run to preview everything:**

```bash
./scripts/provision-two-app-regs.sh --dry-run
```

**Step 3 — Run for real:**

```bash
./scripts/provision-two-app-regs.sh
```

### Options

| Flag | Description |
|------|-------------|
| `--dry-run` | Print write commands without executing (read operations still run) |
| `-h`, `--help` | Show usage |

### What it creates

| Resource | Type | Notes |
|----------|------|-------|
| `cloud-helper-mcp-repro` | Entra app registration | RS-mode, `http://localhost` only |
| `cloud-helper-mcp-fixed` | Entra app registration | RS-mode, adds `http://127.0.0.1` |
| `cloud-helper-fastmcp` | Azure App Service (Python 3.12) | Reuses existing plan |
| `cloud-helper-fastmcp/staging` | App Service slot | Points to fixed app reg |

### After provisioning

1. **Deploy the server** to both slots (TBD once server is packaged)
2. **Run repro test** against production: `uv run client/test_client.py repro`
3. **Run fix test** against staging: `uv run client/test_client.py fixed`
4. **Cut over** when validated: uncomment and run Step 9 in the script

---

## setup-entra-rs-mode.sh

### What it does

Registers an MCP server in Entra ID **RS-mode** (Resource Server) — the production architecture.

RS-mode means:
- The MCP server acts as a **protected API** (resource server), not an OAuth authorization server
- Clients (VS Code, AI Foundry, test tools) obtain Bearer tokens directly from Entra ID
- Clients POST those tokens to the MCP server as `Authorization: Bearer <token>`
- Server validates tokens via JWT inspection (no token exchange)
- This matches RFC 9728 (Protected Resource Model) and VS Code / Foundry expectations

This script creates a new app registration (or reuses an existing one) configured as:
1. **Application ID URI:** `api://{client_id}` — identifies the resource server
2. **OAuth2 delegated permission scope:** `mcp.access` — clients request this scope from Entra
3. **Token version v2:** Required for RS-mode Bearer token validation
4. **No redirect URIs:** RS-mode servers don't participate in redirect flows

### When to use this script

**Use this for production setup:** Run `setup-entra-rs-mode.sh` first to register the API.

**Use `fix-entra-redirect-uri.sh` only if:** You need to test with a public client (e.g., test scripts binding to `127.0.0.1`). The redirect URI fix is for local testing only.

**Order:** RS-mode setup first, then optionally apply redirect URI fix for test clients.

### Prerequisites

- **Azure CLI** (`az`) installed and on PATH  
  → https://docs.microsoft.com/cli/azure/install-azure-cli
- **Logged in** to Azure CLI: `az login`
- **Access** to the tenant containing the app registration  
  (for this project: "Cloud Brokers - ASC Testing" tenant — contact Valeria Morales / resource owner)
- The user running the script must have **Application Administrator** or **Owner**
  role on the tenant to create app registrations

### Usage

```bash
chmod +x scripts/setup-entra-rs-mode.sh

# Minimal — uses current tenant, default app name "cloud-helper-mcp"
./scripts/setup-entra-rs-mode.sh

# Specify subscription (tenant auto-resolved)
./scripts/setup-entra-rs-mode.sh \
  --subscription "Cloud Brokers - ASC Testing"

# Fully explicit — tenant + app name
./scripts/setup-entra-rs-mode.sh \
  --tenant-id "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" \
  --app-name  "cloud-helper-mcp"

# Dry run — see what would happen without making any changes
./scripts/setup-entra-rs-mode.sh \
  --subscription "Cloud Brokers - ASC Testing" \
  --dry-run
```

### Options

| Flag | Description |
|------|-------------|
| `--tenant-id <id>` | Entra tenant GUID or domain |
| `--subscription <name\|id>` | Azure subscription name or ID |
| `--app-name <name>` | App registration display name (default: `cloud-helper-mcp`) |
| `--dry-run` | Show what would be done; make no changes |
| `-h`, `--help` | Show usage |

### Expected output

```
── Checking prerequisites ──
✅ az CLI found: 2.x.x
✅ Logged in as: user@example.com

── Tenant / subscription selection ──
ℹ  Active subscription: Cloud Brokers - ASC Testing

── Locating or creating app registration ──
ℹ  Checking for existing app: 'cloud-helper-mcp'
✅ Found existing app 'cloud-helper-mcp' → Object ID: yyyy-yyyy-...

── Setting up Application ID URI ──
ℹ  Application ID URI already set: api://yyyy-yyyy-...

── Configuring OAuth2 permission scope ──
✅ OAuth2 scope 'mcp.access' created.

── Configuring token settings ──
✅ Token version set to v2.

── RS-mode setup complete ──

  App Configuration:
    • Display Name:         cloud-helper-mcp
    • App ID (client_id):   yyyy-yyyy-...
    • Application ID URI:   api://yyyy-yyyy-...
    • OAuth2 Scope:         api://yyyy-yyyy-.../mcp.access
    • Token Version:        v2

  Environment Variables (.env):
    export AZURE_CLIENT_ID="yyyy-yyyy-..."
    export AZURE_TENANT_ID="xxxx-xxxx-..."
    export MCP_RESOURCE_SCOPE="api://yyyy-yyyy-.../mcp.access"

  ✅ New app registration ready for Resource Server mode.
```

The script is **idempotent** — if the app and scope already exist it skips creation and exits cleanly.

### After running

1. **Pass environment variables to your MCP server:**
   ```bash
   export AZURE_CLIENT_ID="<app_id_from_script>"
   export AZURE_TENANT_ID="<tenant_id>"
   export MCP_RESOURCE_SCOPE="api://<app_id>/mcp.access"
   ```

2. **Configure server to validate Bearer tokens:**
   - Server listens for requests with `Authorization: Bearer <token>`
   - Validates token signature using Entra ID's public keys (via OIDC metadata endpoint)
   - Rejects requests with missing or invalid tokens

3. **Clients obtain tokens and request access:**
   ```
   POST https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token
   scope=api://{client_id}/mcp.access
   ```
   Then:
   ```
   POST https://cloud-helper-mcp.azurewebsites.net/mcp/invoke
   Authorization: Bearer <token_from_entra>
   ```

---

## fix-entra-redirect-uri.sh

### What it does

Adds `http://127.0.0.1` as a **public-client (Mobile/Desktop)** redirect URI to
an Entra app registration, preserving all existing URIs.

**Root cause this fixes:**  
Per RFC 8252 §8.3, `localhost` and `127.0.0.1` are distinct loopback
identifiers. MCP clients bind their OAuth callback listener to `127.0.0.1` and
send `http://127.0.0.1:<port>/` as `redirect_uri` in the `/authorize` request.
If only `http://localhost` is registered in Entra, the redirect URI validation
fails and the token exchange never completes.

### Prerequisites

- **Azure CLI** (`az`) installed and on PATH  
  → https://docs.microsoft.com/cli/azure/install-azure-cli
- **Logged in** to Azure CLI: `az login`
- **Access** to the tenant containing the app registration  
  (for this project: "Cloud Brokers - ASC Testing" tenant — contact Valeria Morales / resource owner)
- The user running the script must have **Application Administrator** or **Owner**
  role on the app registration to update redirect URIs

### Usage

```bash
chmod +x scripts/fix-entra-redirect-uri.sh

# Minimal — uses current tenant, looks up "cloud-helper-mcp" by name
./scripts/fix-entra-redirect-uri.sh

# Specify subscription (tenant auto-resolved)
./scripts/fix-entra-redirect-uri.sh \
  --subscription "Cloud Brokers - ASC Testing"

# Fully explicit — tenant + app object ID (most reliable)
./scripts/fix-entra-redirect-uri.sh \
  --tenant-id "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" \
  --app-id    "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"

# Look up by display name in a specific subscription
./scripts/fix-entra-redirect-uri.sh \
  --subscription "Cloud Brokers - ASC Testing" \
  --app-name     "cloud-helper-mcp"

# Dry run — see what would happen without making any changes
./scripts/fix-entra-redirect-uri.sh \
  --subscription "Cloud Brokers - ASC Testing" \
  --dry-run
```

### Options

| Flag | Description |
|------|-------------|
| `--tenant-id <id>` | Entra tenant GUID or domain |
| `--subscription <name\|id>` | Azure subscription name or ID |
| `--app-id <id>` | App registration object ID (preferred over `--app-name`) |
| `--app-name <name>` | App registration display name (fallback — defaults to `cloud-helper-mcp`) |
| `--dry-run` | Show what would be done; make no changes |
| `-h`, `--help` | Show usage |

### Expected output

```
── Checking prerequisites ──
✅ az CLI found: 2.x.x
✅ Logged in as: user@example.com

── Tenant / subscription selection ──
ℹ  Active subscription: Cloud Brokers - ASC Testing

── Locating app registration ──
✅ Found app 'cloud-helper-mcp' → Object ID: yyyy-yyyy-...

── Current redirect URI state ──
  Public-client redirect URIs:
    • http://localhost

── Idempotency check ──
ℹ  http://127.0.0.1 is NOT currently registered — will add it.

  New public-client redirect URIs will be:
    • http://127.0.0.1
    • http://localhost

── Applying change ──
✅ az ad app update completed.

── Verification ──
  Registered public-client redirect URIs (after update):
    • http://127.0.0.1
    • http://localhost
✅ http://127.0.0.1 confirmed present in app registration.

✅ Done. Entra app registration is now RFC 8252 §8.3-compliant for loopback clients.
```

The script is **idempotent** — if `http://127.0.0.1` is already registered it
exits cleanly with `✅ ... already registered. Nothing to do.`

### After running

1. Re-test the OAuth PKCE flow: `uv run client/test_client.py repro`
2. Verify `/.well-known/oauth-authorization-server` advertises both loopback URIs
3. Confirm CORS on `cloud-helper-mcp` allows Foundry/VS Code origins
