from __future__ import annotations

import logging

import uvicorn
from fastmcp import Context, FastMCP
from fastmcp.server.auth import RemoteAuthProvider
from fastmcp.server.auth.providers.jwt import JWTVerifier
from mcp.server.auth.middleware.auth_context import get_access_token

from config import get_settings

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
)
logger = logging.getLogger(__name__)


def _entra_scope_resource() -> str:
    settings = get_settings()
    audience = settings.audience
    if audience:
        return audience.removesuffix("/mcp.access")
    if settings.client_id.startswith(("api://", "http://", "https://")):
        return settings.client_id.removesuffix("/mcp.access")
    return f"api://{settings.client_id}"


def extract_token_info() -> dict[str, str]:
    access_token = get_access_token()
    if not access_token:
        return {}

    claims = access_token.claims or {}
    return {
        "display_name": (
            claims.get("name")
            or claims.get("preferred_username")
            or claims.get("upn")
            or claims.get("email")
            or access_token.client_id
        ),
        "upn": (
            claims.get("preferred_username")
            or claims.get("upn")
            or claims.get("email")
            or ""
        ),
        "oid": claims.get("oid") or claims.get("sub") or "",
        "tid": claims.get("tid") or "",
    }


def _create_mcp() -> FastMCP:
    settings = get_settings()

    entra_verifier = JWTVerifier(
        jwks_uri=settings.jwks_url,
        issuer=settings.issuer,
        audience=settings.jwt_audience,
        required_scopes=["mcp.access"],
    )

    auth = RemoteAuthProvider(
        token_verifier=entra_verifier,
        authorization_servers=[settings.issuer],
        base_url=settings.resource_url,
        scopes_supported=[f"{_entra_scope_resource()}/mcp.access"],
        resource_name="Cloud Helper MCP",
    )

    return FastMCP(
        "Cloud Helper MCP",
        auth=auth,
    )


mcp = _create_mcp()


@mcp.tool(description="Return a hello world message for authenticated callers.")
def hello(name: str, ctx: Context) -> str:
    access_token = get_access_token()
    if not access_token:
        return f"Hello, {name}! (unauthenticated)"

    token_info = extract_token_info()
    display_name = token_info.get("display_name", access_token.client_id)
    upn = token_info.get("upn", "")
    oid = token_info.get("oid", "")
    tid = token_info.get("tid", "")

    ctx.info(f"hello invoked by {display_name} (oid={oid})")
    return (
        f"Hello, {name}! You are authenticated as:\n"
        f"  Name:    {display_name}\n"
        f"  UPN:     {upn}\n"
        f"  OID:     {oid}\n"
        f"  Tenant:  {tid}\n"
        f"  Scopes:  {', '.join(access_token.scopes)}"
    )


# http_app() replaces streamable_http_app() in fastmcp 3.x.
# stateless_http and json_response moved here from the FastMCP() constructor.
#
# DNS-rebinding protection: fastmcp 3.x no longer exposes transport_security.
# The underlying mcp SDK's check is not wired in by default here.
# Azure App Service enforces TLS + hostname routing, so no custom middleware needed.
app = mcp.http_app(
    stateless_http=True,
    json_response=True,
)


def main() -> None:
    settings = get_settings()
    uvicorn.run(app, host="0.0.0.0", port=settings.port)


if __name__ == "__main__":
    main()
