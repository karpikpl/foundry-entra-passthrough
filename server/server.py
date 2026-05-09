from __future__ import annotations

import asyncio
import json
import logging
from contextlib import asynccontextmanager
from typing import Iterable

import uvicorn
from mcp.server.fastmcp import Context, FastMCP
from starlette.applications import Starlette
from starlette.datastructures import Headers
from starlette.middleware import Middleware
from starlette.routing import Mount
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from auth import (
    AuthError,
    EntraTokenValidator,
    extract_token_scopes,
    get_token_claims,
    reset_token_claims,
    set_token_claims,
)
from config import Settings, get_settings
from well_known import AuthorizationServerMetadataCache, build_well_known_routes

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
)
logger = logging.getLogger(__name__)


class LazyFastMCPApp:
    def __init__(self, factory):
        self.factory = factory
        self._app: ASGIApp | None = None
        self._lock = asyncio.Lock()

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if self._app is None:
            async with self._lock:
                if self._app is None:
                    self._app = self.factory()
        await self._app(scope, receive, send)


class BearerTokenAuthMiddleware:
    def __init__(
        self,
        app: ASGIApp,
        validator: EntraTokenValidator,
        resource_url: str,
        required_scopes: Iterable[str] = ("mcp.access",),
    ):
        self.app = app
        self.validator = validator
        self.required_scopes = tuple(required_scopes)
        self.resource_metadata_url = f"{resource_url}/.well-known/oauth-protected-resource"

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope.get("type") != "http":
            await self.app(scope, receive, send)
            return

        path = scope.get("path", "")
        if not path.startswith("/mcp"):
            await self.app(scope, receive, send)
            return

        headers = Headers(scope=scope)
        auth_header = headers.get("authorization")
        if not auth_header or not auth_header.lower().startswith("bearer "):
            await self._send_oauth_error(send, 401, "invalid_token", "Missing bearer token.")
            return

        token = auth_header.split(" ", 1)[1].strip()
        try:
            claims = await asyncio.to_thread(self.validator.validate_token, token)
        except AuthError as exc:
            await self._send_oauth_error(send, 401, "invalid_token", exc.error_description)
            return

        scopes = extract_token_scopes(claims)
        missing_scopes = [required_scope for required_scope in self.required_scopes if required_scope not in scopes]
        if missing_scopes:
            await self._send_oauth_error(
                send,
                403,
                "insufficient_scope",
                f"Required scope: {' '.join(missing_scopes)}",
            )
            return

        logger.info("Validated bearer token for sub=%s", claims.get("sub", "<unknown>"))
        scope["auth_claims"] = claims
        token_context = set_token_claims(claims)
        try:
            await self.app(scope, receive, send)
        finally:
            reset_token_claims(token_context)

    async def _send_oauth_error(self, send: Send, status_code: int, error: str, description: str) -> None:
        body = json.dumps({"error": error, "error_description": description}).encode("utf-8")
        www_authenticate = (
            'Bearer '
            f'resource_metadata="{self.resource_metadata_url}", '
            f'error="{error}", '
            f'error_description="{description}"'
        )

        start_message: Message = {
            "type": "http.response.start",
            "status": status_code,
            "headers": [
                (b"content-type", b"application/json"),
                (b"content-length", str(len(body)).encode("ascii")),
                (b"www-authenticate", www_authenticate.encode("utf-8")),
            ],
        }
        body_message: Message = {"type": "http.response.body", "body": body}
        await send(start_message)
        await send(body_message)


mcp = FastMCP("Hello World RS-Mode MCP", streamable_http_path="/")


@mcp.tool(description="Return a hello world message for authenticated callers.")
def hello(name: str, ctx: Context) -> str:
    claims = get_token_claims()
    if claims is None:
        raise RuntimeError("Authentication claims were unavailable in the tool context.")

    subject = claims.get("sub", "<unknown>")
    ctx.info(f"hello invoked by {subject}")
    return f"Hello, {name}! You are authenticated."


@asynccontextmanager
async def lifespan(app: Starlette):
    settings: Settings = app.state.settings
    metadata_cache: AuthorizationServerMetadataCache = app.state.authorization_server_metadata_cache
    validator: EntraTokenValidator = app.state.token_validator

    try:
        await metadata_cache.refresh()
        logger.info("Fetched Entra authorization server metadata from %s", settings.authorization_server_metadata_url)
    except Exception as exc:  # pragma: no cover - network failures are deployment-specific
        logger.warning("Unable to preload Entra authorization metadata: %s", exc)

    try:
        await asyncio.to_thread(validator.get_jwks)
        logger.info("Fetched Entra JWKS from %s", settings.jwks_url)
    except Exception as exc:  # pragma: no cover - network failures are deployment-specific
        logger.warning("Unable to preload Entra JWKS: %s", exc)

    yield


def create_app() -> Starlette:
    settings = get_settings()
    validator = EntraTokenValidator(
        tenant_id=settings.tenant_id,
        client_id=settings.client_id,
        audience=settings.resolved_audience,
    )
    metadata_cache = AuthorizationServerMetadataCache(settings.authorization_server_metadata_url)
    mcp_app = LazyFastMCPApp(mcp.streamable_http_app)

    app = Starlette(
        debug=False,
        routes=[
            *build_well_known_routes(),
            Mount("/mcp", app=mcp_app),
        ],
        middleware=[
            Middleware(
                BearerTokenAuthMiddleware,
                validator=validator,
                resource_url=settings.resource_url,
                required_scopes=["mcp.access"],
            )
        ],
        lifespan=lifespan,
    )
    app.state.settings = settings
    app.state.token_validator = validator
    app.state.authorization_server_metadata_cache = metadata_cache
    app.state.mcp_app = mcp_app
    return app


app = create_app()


def main() -> None:
    settings = get_settings()
    uvicorn.run(app, host="0.0.0.0", port=settings.port)


if __name__ == "__main__":
    main()
