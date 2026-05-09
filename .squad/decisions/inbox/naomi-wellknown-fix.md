# Well-Known Route Fix Report — Naomi

**Status:** ✅ Fixed in Azure runtime and verified on both slots  
**Date:** 2026-05-09T16:34:45Z  
**Requested by:** Piotr

## What I checked

1. `server/startup.sh`
2. `server/pyproject.toml`
3. `server/server.py`
4. Azure App Service config, app settings, and logs
5. Live prod/staging endpoints

## Diagnosis

The root Starlette app already registered the well-known routes correctly:

```python
app = Starlette(
    routes=[
        *build_well_known_routes(),
        Mount("/mcp", app=mcp_app),
    ],
)
```

The deployed failure was not in route construction.

### Actual live problems

1. **Wrong App Service startup behavior**
   - `appCommandLine` was empty on both prod and staging.
   - App Service fell back to its default gunicorn hosting app.
   - Symptom matched exactly:
     - `/` returned Azure hosting page / default app
     - `/mcp` returned 404
     - `/.well-known/oauth-protected-resource` returned 404

2. **Missing required env var name**
   - Azure app settings had `AZURE_TENANT_ID`
   - App startup also needed `TENANT_ID`
   - Once I forced direct ASGI startup, missing `TENANT_ID` caused app startup failure until added.

## Fix applied in Azure

### Runtime config

Set startup command on both slots to launch the ASGI app directly:

```bash
python -m uvicorn server:app --host 0.0.0.0 --port 8000
```

### App settings

Added slot-sticky `TENANT_ID` on both prod and staging:

```text
TENANT_ID = c29d6c2b-f765-41b3-b2a2-971a14239dfd
```

### Deployments

- `AZD_DEPLOY_SERVER_SLOT_NAME=staging azd deploy` ✅
- `AZD_DEPLOY_SERVER_SLOT_NAME=production azd deploy` ⚠️ azd wait timed out, but the app finished coming up and served the correct runtime afterward.

## Verification

### Production

```http
GET https://cloud-helper-fastmcp.azurewebsites.net/.well-known/oauth-protected-resource
→ 200 OK
→ server: uvicorn
```

### Staging

```http
GET https://cloud-helper-fastmcp-staging.azurewebsites.net/.well-known/oauth-protected-resource
→ 200 OK
→ server: uvicorn
```

### MCP auth behavior

Both slots now return the expected Bearer auth challenge on `/mcp`:

```http
401 Unauthorized
WWW-Authenticate: Bearer resource_metadata="https://.../.well-known/oauth-protected-resource", ...
```

## Repo state

The repo already had the right application-level fix direction in HEAD:

- `server/startup.sh` starts `server:app`
- `config.py` accepts `TENANT_ID` / `AZURE_TENANT_ID`
- `infra/modules/appService.bicep` encodes the intended startup/env configuration

So the production bug was primarily **deployed Azure config/runtime drift**, not missing Starlette routes.

## Final outcome

- Prod well-known endpoint fixed
- Staging well-known endpoint fixed
- `/mcp` now reaches the intended ASGI app on both slots
- Root cause recorded as App Service startup/config drift, not route code
