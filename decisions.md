# Decisions Log

## 2026-05-09: UV Migration & AZD+Bicep Infrastructure

### D1: UV Migration for server/ and client/ (Naomi)

**Date:** 2026-05-09T04:22:42Z  
**Status:** COMPLETE

Migrated `server/` and `client/` from pip/venv to UV for dependency management, virtual environments, and script execution.

**Key Decisions:**
- `pyproject.toml` replaces `requirements.txt` as primary source; `requirements.txt` retained with DEPRECATED header as fallback
- Entry point is `server:main`, wrapping `uvicorn.run(app, ...)`
- App Service startup: `bash startup.sh` runs `uv run uvicorn server:app --host 0.0.0.0 --port ${PORT:-8080}`
- Dropped unused deps (`fastapi`, `python-dotenv`); Starlette via `mcp[cli]`, pydantic-settings native
- Client external dep: `requests` only
- Makefile at repo root for convenience (`make install`, `make dev`, `make client-run`)

**Files Changed:**
- `server/pyproject.toml`, `server/uv.lock`, `server/startup.sh` — CREATED
- `server/server.py`, `server/README.md`, `server/requirements.txt` — MODIFIED
- `client/pyproject.toml`, `client/uv.lock`, `client/README.md`, `client/requirements.txt` — CREATED/MODIFIED
- `Makefile` — CREATED (repo root)

---

### D2: AZD + Bicep Migration for Infra Provisioning (Amos)

**Date:** 2026-05-09T04:22:42Z  
**Status:** IMPLEMENTED

Migrated all Azure provisioning from bash script to AZD (Azure Developer CLI) + Bicep for repeatable, declarative infrastructure.

**Key Decisions:**
- `azd provision` → Bicep templates create Entra app regs + App Service + slots
- `azd deploy` → AZD deploys FastMCP Python server from `server/`
- Bash script retained as fallback, header updated
- Microsoft.Graph Bicep extension for Entra resources (declarative, idempotent)
- Identifier URIs: `api://cloud-helper-mcp-repro` (repro) and `api://cloud-helper-mcp-fixed` (fixed)
- Slot assignment: production=repro (H1 bug), staging=fixed (H1 corrected)
- Sticky settings on both slots: `CLIENT_ID`, `AUDIENCE`, `RESOURCE_HOST`, `AZURE_TENANT_ID`
- Optional existing App Service Plan reuse via `existingPlanName` parameter

**Files Created/Modified:**
- `azure.yaml` — AZD project config (binds `server/` to app service)
- `infra/bicepconfig.json` — MS Graph Bicep extension config
- `infra/main.bicep`, `infra/main.parameters.json` — Orchestrator + env bindings
- `infra/modules/appRegistrations.bicep`, `infra/modules/appService.bicep` — Resource modules
- `infra/README.md` — Operator runbook
- `scripts/provision-two-app-regs.sh` — Header updated to flag superseded

---

## Summary

| Category | UV Migration | AZD+Bicep |
|----------|--------------|-----------|
| Status | COMPLETE | IMPLEMENTED |
| Agent | Naomi | Amos |
| Python/Deps | pyproject.toml + uv.lock | N/A |
| Infra | N/A | Bicep (declarative) |
| Deployment | startup.sh | AZD + App Service |
