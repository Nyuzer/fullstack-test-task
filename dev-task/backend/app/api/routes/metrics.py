from typing import Any

from fastapi import APIRouter, Depends
from sqlmodel import func, select

from app.api.deps import SessionDep, require
from app.core.permissions import Permission
from app.models import Item, Metrics, User

router = APIRouter(prefix="/metrics", tags=["metrics"])


@router.get(
    "/",
    dependencies=[Depends(require(Permission.METRICS_READ))],
    response_model=Metrics,
)
def read_metrics(session: SessionDep) -> Any:
    """
    Instance-wide counts for the metrics/insights page.
    """
    total_users = session.exec(select(func.count()).select_from(User)).one()
    active_users = session.exec(
        select(func.count()).select_from(User).where(User.is_active)
    ).one()
    total_items = session.exec(select(func.count()).select_from(Item)).one()

    return Metrics(
        total_users=total_users,
        active_users=active_users,
        total_items=total_items,
    )
