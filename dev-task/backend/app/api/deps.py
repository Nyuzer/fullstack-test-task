import logging
from collections.abc import Callable, Generator
from typing import Annotated

import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from jwt.exceptions import InvalidTokenError
from pydantic import ValidationError
from sqlmodel import Session

from app.core import security
from app.core.config import settings
from app.core.db import engine
from app.core.permissions import Permission, has_permission
from app.models import TokenPayload, User

logger = logging.getLogger(__name__)

reusable_oauth2 = OAuth2PasswordBearer(
    tokenUrl=f"{settings.API_V1_STR}/login/access-token"
)


def _unauthenticated(detail: str) -> HTTPException:
    """401: we cannot establish who the caller is (missing, invalid or stale token)."""
    return HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail=detail,
        headers={"WWW-Authenticate": "Bearer"},
    )


def get_db() -> Generator[Session]:
    with Session(engine) as session:
        yield session


SessionDep = Annotated[Session, Depends(get_db)]
TokenDep = Annotated[str, Depends(reusable_oauth2)]


def get_current_user(session: SessionDep, token: TokenDep) -> User:
    try:
        payload = jwt.decode(
            token, settings.SECRET_KEY, algorithms=[security.ALGORITHM]
        )
        token_data = TokenPayload(**payload)
    except (InvalidTokenError, ValidationError):
        raise _unauthenticated("Could not validate credentials")
    user = session.get(User, token_data.sub)
    if not user:
        # The token is well-formed but its subject is gone. That is still an
        # authentication failure, not a missing resource.
        raise _unauthenticated("Could not validate credentials")
    if not user.is_active:
        raise _unauthenticated("Inactive user")
    return user


CurrentUser = Annotated[User, Depends(get_current_user)]


def require(permission: Permission) -> Callable[[User], User]:
    """Build a dependency that admits only callers holding `permission`.

    403: we know who you are, you may not do this.
    """

    def check_permission(current_user: CurrentUser) -> User:
        if not has_permission(current_user.role, permission):
            # str() not .value: SQLModel skips validation on table instances, so
            # `role` arrives from the database as a plain string.
            logger.warning(
                "Denied %s for user_id=%s role=%s",
                permission.value,
                current_user.id,
                str(current_user.role),
            )
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="The user doesn't have enough privileges",
            )
        return current_user

    return check_permission
