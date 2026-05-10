from __future__ import annotations

import asyncio
import logging

import uvicorn
from mcp.server.auth.middleware.auth_context import get_access_token
from mcp.server.auth.provider import AccessToken, TokenVerifier
from mcp.server.auth.settings import AuthSettings
from mcp.server.fastmcp import Context, FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from pydantic import AnyHttpUrl

from auth import AuthError, EntraTokenValidator, extract_token_scopes
from config import get_settings

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
)
logger = logging.getLogger(__name__)


class EntraTokenVerifier:
    """Adapts EntraTokenValidator to FastMCP's TokenVerifier protocol."""

    def __init__(self, validator: EntraTokenValidator) -> None:
        self._validator = validator

    async def verify_token(self, token: str) -> AccessToken | None:
        try:
            claims = await asyncio.to_thread(self._validator.validate_token, token)
        except AuthError as exc:
            logger.warning("Token validation failed: %s", exc.error_description)
            return None

        scopes = extract_token_scopes(claims)
        subject = claims.get("sub", claims.get("appid", "unknown"))
        logger.info("Validated bearer token for sub=%s", subject)
        return AccessToken(
            token=token,
            client_id=subject,
            scopes=list(scopes),
            expires_at=claims.get("exp"),
        )


def _create_mcp() -> FastMCP:
    settings = get_settings()
    validator = EntraTokenValidator(
        tenant_id=settings.tenant_id,
        client_id=settings.client_id,
        audience=settings.resolved_audience,
    )
    return FastMCP(
        "Hello World RS-Mode MCP",
        auth=AuthSettings(
            issuer_url=AnyHttpUrl(settings.issuer),
            resource_server_url=AnyHttpUrl(f"{settings.resource_url}/mcp"),
            required_scopes=["mcp.access"],
        ),
        token_verifier=EntraTokenVerifier(validator),
        stateless_http=True,
        json_response=True,
        # Disable DNS-rebinding protection — tokens are validated by Entra.
        # The default localhost-only allowed_hosts would reject every request
        # when deployed on Azure App Service.
        transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
    )


mcp = _create_mcp()


@mcp.tool(description="Return a hello world message for authenticated callers.")
def hello(name: str, ctx: Context) -> str:
    access_token = get_access_token()
    subject = access_token.client_id if access_token else "<unknown>"
    ctx.info(f"hello invoked by {subject}")
    return f"Hello, {name}! You are authenticated."


# streamable_http_app() wires up:
#   - /.well-known/oauth-protected-resource/mcp  (RFC 9728, with scopes_supported)
#   - AuthenticationMiddleware + BearerAuthBackend + AuthContextMiddleware
#   - RequireAuthMiddleware protecting /mcp
#   - session_manager lifespan
app = mcp.streamable_http_app()


def main() -> None:
    settings = get_settings()
    uvicorn.run(app, host="0.0.0.0", port=settings.port)


if __name__ == "__main__":
    main()
