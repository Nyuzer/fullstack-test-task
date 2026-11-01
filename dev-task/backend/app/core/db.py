from sqlmodel import Session, create_engine, select

from app import crud
from app.core.config import settings
from app.core.permissions import UserRole
from app.models import User, UserCreate

engine = create_engine(str(settings.DATABASE_URL), pool_pre_ping=True)


# make sure all SQLModel models are imported (app.models) before initializing DB
# otherwise, SQLModel might fail to initialize relationships properly
# for more details: https://github.com/fastapi/full-stack-fastapi-template/issues/28


def init_db(session: Session) -> None:
    # Tables should be created with Alembic migrations
    # But if you don't want to use migrations, create
    # the tables un-commenting the next lines
    # from sqlmodel import SQLModel

    # This works because the models are already imported and registered from app.models
    # SQLModel.metadata.create_all(engine)

    seed_user(session, settings.FIRST_SUPERUSER, UserRole.ADMIN)

    # Demo accounts for the other roles, so the permission matrix can be
    # exercised end to end. Development only: never seed these in production.
    if settings.FASTAPI_ENV == "development":
        seed_user(session, settings.FIRST_MANAGER, UserRole.MANAGER)
        seed_user(session, settings.FIRST_MEMBER, UserRole.MEMBER)


def seed_user(session: Session, email: str, role: UserRole) -> User:
    """Create `email` with `role` if it does not exist yet. Idempotent."""
    user = session.exec(select(User).where(User.email == email)).first()
    if not user:
        user = crud.create_user(
            session=session,
            user_create=UserCreate(
                email=email,
                password=settings.FIRST_SUPERUSER_PASSWORD,
                role=role,
            ),
        )
    return user
