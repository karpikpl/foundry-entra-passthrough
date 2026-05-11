from __future__ import annotations

import logging

import uvicorn
from fastmcp import Context, FastMCP
from fastmcp.server.auth import OAuthProxy
from fastmcp.server.auth.providers.jwt import JWTVerifier
from mcp.server.auth.middleware.auth_context import get_access_token

from config import get_settings

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
)
logger = logging.getLogger(__name__)


def _create_mcp() -> FastMCP:
    settings = get_settings()

    # WHY OAuthProxy instead of RS-mode (TokenVerifier + AuthSettings)?
    #
    # In RS-mode, the /.well-known/oauth-protected-resource response advertises
    # Entra's URL (login.microsoftonline.com/<tenant>/v2.0) as the auth server.
    #
    # VS Code's microsoft-authentication extension registers itself as the handler
    # for any auth server matching "https://login.microsoftonline.com/*".  When it
    # handles MCP auth it bundles Microsoft Graph (resource 00000003) scopes so it
    # can populate the Accounts panel with the user's name and profile picture.
    #
    # Entra blocks this with AADSTS65002: VS Code (app aebc6443, a Microsoft
    # first-party app) is not pre-authorised to request Graph (also a Microsoft
    # first-party resource) in any *third-party* tenant.  This fails for every
    # account type (member or guest) in any custom Entra tenant — there is no
    # per-tenant workaround.
    #
    # OAuthProxy fixes this by presenting OUR OWN server URL as the auth server.
    # VS Code doesn't match it against login.microsoftonline.com/* so it falls back
    # to a plain OAuth 2.1 PKCE flow that requests ONLY the scopes we specify.
    # No Graph request → no AADSTS65002.
    #
    # The proxy:
    #   1. Exposes /auth/register, /auth/authorize, /auth/token on our domain.
    #   2. Accepts Dynamic Client Registration (DCR) from any MCP client.
    #   3. Redirects the user to Entra for real authentication.
    #   4. After Entra callback, validates the Entra JWT (via JWTVerifier below).
    #   5. Issues its own short-lived FastMCP JWT to the MCP client.
    #   6. MCP clients send that FastMCP JWT as the Bearer token to /mcp.
    #
    # PREREQUISITE: register the proxy's fixed callback URI in the Entra app:
    #   {RESOURCE_HOST}/auth/callback
    # e.g. https://cloud-helper-fastmcp-staging.azurewebsites.net/auth/callback

    # JWTVerifier validates the upstream Entra token that arrives at the proxy
    # callback, before the proxy issues its own FastMCP JWT to the client.
    entra_verifier = JWTVerifier(
        jwks_uri=settings.jwks_url,
        issuer=settings.issuer,
        audience=settings.resolved_audience,
        required_scopes=["mcp.access"],
    )

    auth = OAuthProxy(
        # Entra's standard OAuth 2.0 v2.0 endpoints for our tenant.
        upstream_authorization_endpoint=(
            f"https://login.microsoftonline.com/{settings.tenant_id}/oauth2/v2.0/authorize"
        ),
        upstream_token_endpoint=(
            f"https://login.microsoftonline.com/{settings.tenant_id}/oauth2/v2.0/token"
        ),
        # Pre-registered Entra app credentials (client secret required because
        # Entra doesn't support Dynamic Client Registration).
        upstream_client_id=settings.client_id,
        upstream_client_secret=settings.client_secret,
        # Entra v2.0 requires the full scope URI (api://<app-id>/<scope>).
        # We pass it here so the proxy includes it when redirecting to Entra,
        # regardless of what abbreviated scope the MCP client requested.
        extra_authorize_params={
            "scope": f"{settings.resolved_audience}/mcp.access offline_access openid"
        },
        token_verifier=entra_verifier,
        # base_url tells the proxy what URL to advertise for its own auth
        # endpoints (/auth/authorize, /auth/token, /auth/register).
        # Derived from RESOURCE_HOST env var — no hardcoded URLs.
        base_url=settings.resource_url,
        # Entra does not support RFC 8707 resource indicators. VS Code sends
        # resource=<mcp-url> in the authorization request; if forwarded it
        # conflicts with the api:// scope and causes AADSTS9010010.
        forward_resource=False,
    )

    return FastMCP(
        "Cloud Helper MCP",
        auth=auth,
    )


mcp = _create_mcp()


@mcp.tool(description="Return a hello world message for authenticated callers.")
def hello(name: str, ctx: Context) -> str:
    # get_access_token() returns the FastMCP JWT claims for the current request.
    # client_id holds the subject extracted from the upstream Entra token.
    access_token = get_access_token()
    subject = access_token.client_id if access_token else "<unknown>"
    ctx.info(f"hello invoked by {subject}")
    return f"Hello, {name}! You are authenticated as {subject}."


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
