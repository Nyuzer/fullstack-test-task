import uuid
from typing import Any

from sqlmodel import Session, select

from app.core.permissions import UserRole
from app.core.security import get_password_hash, verify_password
from app.models import Item, ItemCreate, User, UserCreate, UserUpdate


def _role_for_new_user(user_create: UserCreate) -> UserRole:
    """Resolve the role of a user being created.

    `role` wins when the caller set it. Callers that still only speak the
    legacy `is_superuser` flag keep working: the flag is translated into a role
    so the two can never be stored out of step.
    """
    fields_set = user_create.model_fields_set
    if "role" not in fields_set and "is_superuser" in fields_set:
        return UserRole.ADMIN if user_create.is_superuser else UserRole.MEMBER
    return user_create.role


def create_user(*, session: Session, user_create: UserCreate) -> User:
    role = _role_for_new_user(user_create)
    db_obj = User.model_validate(
        user_create,
        update={
            "hashed_password": get_password_hash(user_create.password),
            "role": role,
            "is_superuser": role == UserRole.ADMIN,
        },
    )
    session.add(db_obj)
    session.commit()
    session.refresh(db_obj)
    return db_obj


def update_user(*, session: Session, db_user: User, user_in: UserUpdate) -> Any:
    # Drop explicit nulls: every UserUpdate field is optional-to-omit, not
    # nullable in the database, so `{"role": null}` means "leave it alone"
    # rather than "write NULL" (which the NOT NULL column would reject).
    user_data = {
        key: value
        for key, value in user_in.model_dump(exclude_unset=True).items()
        if value is not None
    }
    extra_data: dict[str, Any] = {}
    if "password" in user_data:
        password = user_data["password"]
        hashed_password = get_password_hash(password)
        extra_data["hashed_password"] = hashed_password
    if "role" in user_data:
        extra_data["is_superuser"] = user_data["role"] == UserRole.ADMIN
    db_user.sqlmodel_update(user_data, update=extra_data)
    session.add(db_user)
    session.commit()
    session.refresh(db_user)
    return db_user


def get_user_by_email(*, session: Session, email: str) -> User | None:
    statement = select(User).where(User.email == email)
    session_user = session.exec(statement).first()
    return session_user


# Dummy hash to use for timing attack prevention when user is not found
# This is an Argon2 hash of a random password, used to ensure constant-time comparison
DUMMY_HASH = "$argon2id$v=19$m=65536,t=3,p=4$MjQyZWE1MzBjYjJlZTI0Yw$YTU4NGM5ZTZmYjE2NzZlZjY0ZWY3ZGRkY2U2OWFjNjk"


def authenticate(*, session: Session, email: str, password: str) -> User | None:
    db_user = get_user_by_email(session=session, email=email)
    if not db_user:
        # Prevent timing attacks by running password verification even when user doesn't exist
        # This ensures the response time is similar whether or not the email exists
        verify_password(password, DUMMY_HASH)
        return None
    verified, updated_password_hash = verify_password(password, db_user.hashed_password)
    if not verified:
        return None
    if updated_password_hash:
        db_user.hashed_password = updated_password_hash
        session.add(db_user)
        session.commit()
        session.refresh(db_user)
    return db_user


def create_item(*, session: Session, item_in: ItemCreate, owner_id: uuid.UUID) -> Item:
    db_item = Item.model_validate(item_in, update={"owner_id": owner_id})
    session.add(db_item)
    session.commit()
    session.refresh(db_item)
    return db_item
