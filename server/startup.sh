#!/bin/bash
# Azure App Service startup script.
# App Service startup command: bash startup.sh
set -euo pipefail

exec uv run uvicorn server:app --host 0.0.0.0 --port "${PORT:-8080}"
