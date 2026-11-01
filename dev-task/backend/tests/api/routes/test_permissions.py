"""RBAC tests for roles, permissions and the enforcement dependency.

Written before the implementation exists: they target the planned
``app.core.permissions`` module and the role-aware user/metrics endpoints.
"""

import uuid
from collections.abc import Callable, Generator
from typing import Any
from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient
from sqlmodel import Session

from app import crud
from app.core.config import settings
from app.core.permissions import Permission, UserRole, permissions_for
from app.models import User, UserCreate
from tests.utils.user import user_authentication_headers
from tests.utils.utils import random_email, random_lower_string

API = settings.API_V1_STR
ALL_ROLES = [UserRole.ADMIN, UserRole.MANAGER, UserRole.MEMBER]


@pytest.fixture(autouse=True)
def _no_outbound_email() -> Generator[None]:
    """``POST /users/`` sends a welcome email; keep tests off the network."""
    with patch("app.api.routes.users.send_email", return_value=None):
        yield


def create_user_with_role(
    db: Session, role: UserRole, *, is_active: bool = True
) -> tuple[User, str]:
    """Create a fresh user with ``role``, returning it and its plaintext password."""
    password = random_lower_string()
    user = crud.create_user(
        session=db,
        user_create=UserCreate(email=random_email(), password=password, role=role),
    )
    if not is_active:
        user.is_active = False
        db.add(user)
        db.commit()
        db.refresh(user)
    return user, password


def auth_headers_for(client: TestClient, email: str, password: str) -> dict[str, str]:
    return user_authentication_headers(client=client, email=email, password=password)


def login_as(
    client: TestClient, db: Session, role: UserRole
) -> tuple[User, dict[str, str]]:
    """Create a brand new user with ``role`` and return it plus its auth headers."""
    user, password = create_user_with_role(db, role)
    return user, auth_headers_for(client, user.email, password)


def call(
    client: TestClient,
    method: str,
    path: str,
    headers: dict[str, str],
    json: dict[str, Any] | None = None,
) -> int:
    r = client.request(method, f"{API}{path}", headers=headers, json=json)
    return r.status_code


def new_user_payload() -> dict[str, Any]:
    return {"email": random_email(), "password": random_lower_string()}


# (id, permission, method, path template, body factory)
EndpointCase = tuple[str, Permission, str, str, Callable[[], dict[str, Any]] | None]

ENDPOINTS: list[EndpointCase] = [
    ("list_users", Permission.USERS_READ, "GET", "/users/", None),
    ("create_user", Permission.USERS_CREATE, "POST", "/users/", new_user_payload),
    ("read_metrics", Permission.METRICS_READ, "GET", "/metrics/", None),
    (
        "update_any_user",
        Permission.USERS_UPDATE_ANY,
        "PATCH",
        "/users/{target_id}",
        lambda: {"full_name": random_lower_string()},
    ),
    ("delete_user", Permission.USERS_DELETE, "DELETE", "/users/{target_id}", None),
]


@pytest.mark.parametrize("role", ALL_ROLES, ids=lambda r: str(r.value))
@pytest.mark.parametrize("endpoint", ENDPOINTS, ids=lambda e: e[0])
def test_endpoint_access_matches_role_permission_matrix(
    client: TestClient,
    db: Session,
    role: UserRole,
    endpoint: EndpointCase,
) -> None:
    """Every role x endpoint pair must agree with ``permissions_for(role)``.

    The expectation is derived from the matrix rather than hardcoded, so the
    test fails if the routes and the matrix ever drift apart.
    """
    _, permission, method, path_template, body_factory = endpoint
    _, headers = login_as(client, db, role)
    target, _ = create_user_with_role(db, UserRole.MEMBER)
    path = path_template.format(target_id=target.id)

    body = body_factory() if body_factory else None
    status = call(client, method, path, headers, body)

    if permission in permissions_for(role):
        assert 200 <= status < 300, f"{role} should be allowed {permission}"
    else:
        assert status == 403, f"{role} should be denied {permission}"


# Deliberately redundant with the matrix-driven test above: this spells the
# documented table out cell by cell so a silent edit to ROLE_PERMISSIONS cannot
# make both tests agree with each other. Mirrors ASSIGNMENT.md lines 90-96.
GOLDEN_ROLE_ORDER = (UserRole.ADMIN, UserRole.MANAGER, UserRole.MEMBER)
GOLDEN_MATRIX: dict[str, tuple[bool, bool, bool]] = {
    # action            |  admin | manager | member
    "list_all_users": (True, True, False),
    "create_user": (True, False, False),
    "view_metrics": (True, True, False),
    "update_own_profile": (True, True, True),
    "update_any_profile": (True, False, False),
}


def test_documented_permission_table_holds_cell_by_cell(
    client: TestClient, db: Session
) -> None:
    """Human-readable anchor: the literal table from the assignment docs."""
    for role in ALL_ROLES:
        _, headers = login_as(client, db, role)
        target, _ = create_user_with_role(db, UserRole.MEMBER)
        requests: dict[str, tuple[str, str, dict[str, Any] | None]] = {
            "list_all_users": ("GET", "/users/", None),
            "create_user": ("POST", "/users/", new_user_payload()),
            "view_metrics": ("GET", "/metrics/", None),
            "update_own_profile": ("PATCH", "/users/me", {"full_name": "Own Name"}),
            "update_any_profile": (
                "PATCH",
                f"/users/{target.id}",
                {"full_name": "Other Name"},
            ),
        }
        for action, (method, path, body) in requests.items():
            status = call(client, method, path, headers, body)
            if GOLDEN_MATRIX[action][GOLDEN_ROLE_ORDER.index(role)]:
                assert 200 <= status < 300, f"{role} must be able to {action}"
            else:
                assert status == 403, f"{role} must not be able to {action}"


@pytest.mark.parametrize(
    "escalation_payload",
    [{"role": UserRole.ADMIN.value}, {"is_superuser": True}],
    ids=["role_field", "is_superuser_field"],
)
def test_member_cannot_escalate_own_role_via_update_me(
    client: TestClient, db: Session, escalation_payload: dict[str, Any]
) -> None:
    """The extra field must be ignored; 200 is fine, the DB row is the assertion."""
    user, headers = login_as(client, db, UserRole.MEMBER)
    user_id = user.id

    client.patch(
        f"{API}/users/me",
        headers=headers,
        json={"full_name": "Still A Member", **escalation_payload},
    )

    stored = db.get(User, user_id)
    assert stored is not None
    db.refresh(stored)
    assert stored.role == UserRole.MEMBER
    assert stored.is_superuser is False


def test_signup_ignores_role_in_body_and_creates_a_member(
    client: TestClient, db: Session
) -> None:
    email = random_email()
    r = client.post(
        f"{API}/users/signup",
        json={
            "email": email,
            "password": random_lower_string(),
            "full_name": "Hopeful Admin",
            "role": UserRole.ADMIN.value,
        },
    )
    assert 200 <= r.status_code < 300

    stored = crud.get_user_by_email(session=db, email=email)
    assert stored is not None
    db.refresh(stored)
    assert stored.role == UserRole.MEMBER
    assert stored.is_superuser is False


@pytest.mark.parametrize("role", ALL_ROLES, ids=lambda r: str(r.value))
def test_users_me_reports_the_permissions_of_the_role(
    client: TestClient, db: Session, role: UserRole
) -> None:
    _, headers = login_as(client, db, role)

    r = client.get(f"{API}/users/me", headers=headers)

    assert r.status_code == 200
    body = r.json()
    assert body["role"] == role.value
    assert body["is_superuser"] is (role == UserRole.ADMIN)
    assert set(body["permissions"]) == {p.value for p in permissions_for(role)}


def test_missing_or_invalid_credentials_are_401_while_denied_access_is_403(
    client: TestClient, db: Session
) -> None:
    """401 is "we don't know who you are", 403 is "you may not do this"."""
    assert client.get(f"{API}/users/").status_code == 401
    assert (
        client.get(
            f"{API}/users/", headers={"Authorization": "Bearer not-a-real-token"}
        ).status_code
        == 401
    )

    _, member_headers = login_as(client, db, UserRole.MEMBER)
    r = client.get(f"{API}/users/", headers=member_headers)
    assert r.status_code == 403


@pytest.mark.parametrize("role", ALL_ROLES, ids=lambda r: str(r.value))
def test_inactive_users_are_rejected_whatever_their_role(
    client: TestClient, db: Session, role: UserRole
) -> None:
    """Even an inactive admin is turned away, before any permission check.

    401, not 403: a deactivated account is an authentication failure, so the
    caller is logged out rather than left in a half-authenticated state.
    """
    user, password = create_user_with_role(db, role)
    headers = auth_headers_for(client, user.email, password)

    user.is_active = False
    db.add(user)
    db.commit()

    r = client.get(f"{API}/users/me", headers=headers)
    assert r.status_code == 401
    assert r.json()["detail"] == "Inactive user"


def test_member_keeps_access_to_their_own_profile(
    client: TestClient, db: Session
) -> None:
    """The lockdown must not go too far: own profile stays readable and writable."""
    user, headers = login_as(client, db, UserRole.MEMBER)
    user_id = user.id

    r = client.get(f"{API}/users/me", headers=headers)
    assert r.status_code == 200
    assert r.json()["email"] == user.email

    new_name = random_lower_string()
    r = client.patch(f"{API}/users/me", headers=headers, json={"full_name": new_name})
    assert r.status_code == 200
    assert r.json()["full_name"] == new_name

    stored = db.get(User, user_id)
    assert stored is not None
    db.refresh(stored)
    assert stored.full_name == new_name
    assert stored.role == UserRole.MEMBER


def test_member_cannot_discover_other_user_ids_via_read_user_by_id(
    client: TestClient, db: Session
) -> None:
    # Both an existing and a non-existent id must answer identically, otherwise
    # 403-vs-404 leaks which ids exist. Matches the current route ordering.
    _, headers = login_as(client, db, UserRole.MEMBER)
    other, _ = create_user_with_role(db, UserRole.MANAGER)

    r = client.get(f"{API}/users/{other.id}", headers=headers)
    assert r.status_code == 403

    r = client.get(f"{API}/users/{uuid.uuid4()}", headers=headers)
    assert r.status_code == 403
