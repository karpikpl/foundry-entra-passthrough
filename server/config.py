from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from pydantic import AliasChoices, Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Runtime configuration for the FastMCP protected resource."""

    tenant_id: str = Field(
        validation_alias=AliasChoices("TENANT_ID", "AZURE_TENANT_ID")
    )
    client_id: str = Field(alias="CLIENT_ID")
    audience: str | None = Field(default=None, alias="AUDIENCE")
    resource_app_id: str | None = Field(default=None, alias="RESOURCE_APP_ID")
    resource_host: str = Field(alias="RESOURCE_HOST")
    port: int = Field(default=8000, alias="PORT")

    model_config = SettingsConfigDict(
        env_file=Path(__file__).with_name(".env"),
        env_file_encoding="utf-8",
        extra="ignore",
    )

    @property
    def resolved_audience(self) -> str:
        """Primary audience value configured for this resource server."""
        return self.audience or self.client_id

    @property
    def jwt_audience(self) -> str | list[str]:
        """Audience value(s) accepted when validating Entra access tokens."""
        if self.resource_app_id:
            return [self.resource_app_id, self.resolved_audience]
        return self.resolved_audience

    @property
    def scope_resource(self) -> str:
        """Resource prefix used to advertise the mcp.access scope."""
        if self.audience:
            return self.audience.removesuffix("/mcp.access")
        if self.client_id.startswith(("api://", "http://", "https://")):
            return self.client_id.removesuffix("/mcp.access")
        return f"api://{self.resource_app_id or self.client_id}"

    @property
    def issuer(self) -> str:
        return f"https://login.microsoftonline.com/{self.tenant_id}/v2.0"

    @property
    def jwks_url(self) -> str:
        return f"https://login.microsoftonline.com/{self.tenant_id}/discovery/v2.0/keys"

    @property
    def resource_url(self) -> str:
        return f"https://{self.resource_host}"


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
