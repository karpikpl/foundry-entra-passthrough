from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from pydantic import AliasChoices, Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    tenant_id: str = Field(
        validation_alias=AliasChoices("TENANT_ID", "AZURE_TENANT_ID")
    )
    client_id: str = Field(alias="CLIENT_ID")
    client_secret: str = Field(alias="CLIENT_SECRET")
    audience: str | None = Field(default=None, alias="AUDIENCE")
    # RESOURCE_APP_ID: the fixed app's GUID (not the api:// URI).
    # Entra always sets aud to the GUID in access tokens for custom APIs,
    # even when requestedAccessTokenVersion: 2 and an identifier URI exist.
    resource_app_id: str | None = Field(default=None, alias="RESOURCE_APP_ID")
    resource_host: str = Field(alias="RESOURCE_HOST")
    port: int = Field(default=8000, alias="PORT")

    model_config = SettingsConfigDict(
        env_file=Path(__file__).with_name(".env"),
        env_file_encoding="utf-8",
        extra="ignore",
    )

    @property
    def jwt_audience(self) -> str | list[str]:
        """Audience for JWTVerifier — the fixed app's GUID if known, else the URI.

        Entra always uses the app's GUID (not the api:// identifier URI) as the
        aud claim in access tokens for custom APIs, even with v2 tokens. Accept
        both so the server works regardless of the token version Entra issues.
        """
        if self.resource_app_id:
            return [self.resource_app_id, self.resolved_audience]
        return self.resolved_audience

    @property
    def resolved_audience(self) -> str:
        return self.audience or self.client_id

    @property
    def issuer(self) -> str:
        return f"https://login.microsoftonline.com/{self.tenant_id}/v2.0"

    @property
    def jwks_url(self) -> str:
        return f"https://login.microsoftonline.com/{self.tenant_id}/discovery/v2.0/keys"

    @property
    def authorization_server_metadata_url(self) -> str:
        return f"{self.issuer}/.well-known/openid-configuration"

    @property
    def resource_url(self) -> str:
        return f"https://{self.resource_host}"


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
