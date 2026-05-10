from __future__ import annotations

from typing import Any

import httpx
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

from config import Settings


class AuthorizationServerMetadataCache:
    def __init__(self, metadata_url: str):
        self.metadata_url = metadata_url
        self._metadata: dict[str, Any] | None = None

    async def refresh(self) -> dict[str, Any]:
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.get(self.metadata_url)
            response.raise_for_status()

        payload = response.json()
        if not isinstance(payload, dict):
            raise ValueError("Authorization server metadata must be a JSON object.")

        self._metadata = payload
        return payload

    async def get_metadata(self) -> dict[str, Any]:
        if self._metadata is None:
            return await self.refresh()
        return self._metadata


async def oauth_protected_resource(request: Request) -> JSONResponse:
    settings: Settings = request.app.state.settings
    return JSONResponse(
        {
            "resource": f"{settings.resource_url}/mcp",
            "authorization_servers": [settings.issuer],
            "bearer_methods_supported": ["header"],
            "resource_signing_alg_values_supported": ["RS256"],
            "scopes_supported": ["mcp.access"],
        }
    )


async def oauth_authorization_server(request: Request) -> JSONResponse:
    cache: AuthorizationServerMetadataCache = (
        request.app.state.authorization_server_metadata_cache
    )
    metadata = await cache.get_metadata()
    return JSONResponse(metadata)


def build_well_known_routes() -> list[Route]:
    return [
        Route(
            "/.well-known/oauth-protected-resource",
            endpoint=oauth_protected_resource,
            methods=["GET"],
        ),
        Route(
            "/.well-known/oauth-authorization-server",
            endpoint=oauth_authorization_server,
            methods=["GET"],
        ),
    ]
