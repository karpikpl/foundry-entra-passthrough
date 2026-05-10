from __future__ import annotations

import contextvars
import json
import logging
import threading
import time
from dataclasses import dataclass
from typing import Any

import httpx
import jwt
from jwt import InvalidAudienceError, InvalidIssuerError, InvalidTokenError
from jwt.algorithms import RSAAlgorithm

logger = logging.getLogger(__name__)


@dataclass(slots=True)
class AuthError(Exception):
    error_description: str


_token_claims_var: contextvars.ContextVar[dict[str, Any] | None] = (
    contextvars.ContextVar(
        "token_claims",
        default=None,
    )
)


def set_token_claims(
    claims: dict[str, Any],
) -> contextvars.Token[dict[str, Any] | None]:
    return _token_claims_var.set(claims)


def reset_token_claims(token: contextvars.Token[dict[str, Any] | None]) -> None:
    _token_claims_var.reset(token)


def get_token_claims() -> dict[str, Any] | None:
    return _token_claims_var.get()


class EntraTokenValidator:
    def __init__(self, tenant_id: str, client_id: str, audience: str):
        self.tenant_id = tenant_id
        self.client_id = client_id
        self.audience = audience or f"api://{client_id}"
        self.issuer = f"https://login.microsoftonline.com/{tenant_id}/v2.0"
        self.jwks_url = (
            f"https://login.microsoftonline.com/{tenant_id}/discovery/v2.0/keys"
        )
        self._jwks_cache: dict[str, Any] | None = None
        self._jwks_cached_at = 0.0
        self._cache_ttl_seconds = 3600
        self._lock = threading.Lock()

    def get_jwks(self) -> dict[str, Any]:
        with self._lock:
            now = time.time()
            if (
                self._jwks_cache
                and (now - self._jwks_cached_at) < self._cache_ttl_seconds
            ):
                return self._jwks_cache

            try:
                response = httpx.get(self.jwks_url, timeout=10.0)
                response.raise_for_status()
            except httpx.HTTPError as exc:
                raise AuthError("Unable to fetch Entra JWKS.") from exc

            payload = response.json()
            if not isinstance(payload, dict) or not isinstance(
                payload.get("keys"), list
            ):
                raise AuthError("Entra JWKS response was invalid.")

            self._jwks_cache = payload
            self._jwks_cached_at = now
            return payload

    def validate_token(self, token: str) -> dict[str, Any]:
        if not token:
            raise AuthError("Missing bearer token.")

        try:
            header = jwt.get_unverified_header(token)
        except InvalidTokenError as exc:
            raise AuthError("Bearer token is malformed.") from exc

        kid = header.get("kid")
        if not kid:
            raise AuthError("Bearer token header is missing kid.")

        # Log unverified claims so we can compare aud/iss/scp vs server config
        try:
            unverified = jwt.decode(token, options={"verify_signature": False})
            logger.info(
                "Token claims (unverified) — aud=%r iss=%r scp=%r sub=%r",
                unverified.get("aud"),
                unverified.get("iss"),
                unverified.get("scp"),
                unverified.get("sub"),
            )
        except Exception as exc:
            logger.warning("Could not decode token for logging: %s", exc)

        logger.info(
            "Validating token — expected audience=%r issuer=%r kid=%r",
            self.audience,
            self.issuer,
            kid,
        )

        signing_key = self._find_signing_key(kid)

        try:
            return jwt.decode(
                token,
                key=signing_key,
                algorithms=["RS256"],
                audience=self.audience,
                issuer=self.issuer,
                options={"require": ["exp", "aud", "iss", "sub"]},
            )
        except jwt.ExpiredSignatureError as exc:
            logger.warning("Token rejected: expired")
            raise AuthError("Bearer token has expired.") from exc
        except InvalidAudienceError as exc:
            logger.warning(
                "Token rejected: audience mismatch — token aud=%r expected=%r",
                unverified.get("aud") if "unverified" in dir() else "?",
                self.audience,
            )
            raise AuthError(
                "Bearer token audience did not match this resource."
            ) from exc
        except InvalidIssuerError as exc:
            logger.warning(
                "Token rejected: issuer mismatch — token iss=%r expected=%r",
                unverified.get("iss") if "unverified" in dir() else "?",
                self.issuer,
            )
            raise AuthError("Bearer token issuer was not trusted.") from exc
        except InvalidTokenError as exc:
            logger.warning("Token rejected: %s", exc)
            raise AuthError("Bearer token validation failed.") from exc

    def _find_signing_key(self, kid: str) -> Any:
        jwks = self.get_jwks()
        for key in jwks["keys"]:
            if key.get("kid") == kid:
                return RSAAlgorithm.from_jwk(json.dumps(key))

        with self._lock:
            self._jwks_cache = None
            self._jwks_cached_at = 0.0

        jwks = self.get_jwks()
        for key in jwks["keys"]:
            if key.get("kid") == kid:
                return RSAAlgorithm.from_jwk(json.dumps(key))

        raise AuthError("Bearer token signing key was not published by Entra.")


def extract_token_scopes(claims: dict[str, Any]) -> set[str]:
    scopes: set[str] = set()

    raw_scope = claims.get("scp")
    if isinstance(raw_scope, str):
        scopes.update(scope for scope in raw_scope.split() if scope)

    raw_roles = claims.get("roles")
    if isinstance(raw_roles, list):
        scopes.update(str(role) for role in raw_roles if role)

    return scopes
