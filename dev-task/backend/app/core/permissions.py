"""The authorization model, in one file.

Adding a role means adding a member to :class:`UserRole` and a row to
:data:`ROLE_PERMISSIONS`. Nothing else in the codebase needs to change: routes
depend on permissions, never on role names.
"""

from enum import StrEnum


class UserRole(StrEnum):
    ADMIN = "admin"
    MANAGER = "manager"
    MEMBER = "member"


class Permission(StrEnum):
    USERS_READ = "users:read"
    USERS_CREATE = "users:create"
    USERS_UPDATE_ANY = "users:update_any"
    USERS_DELETE = "users:delete"
    METRICS_READ = "metrics:read"
    SETTINGS_MANAGE = "settings:manage"
    ITEMS_MANAGE_ANY = "items:manage_any"


ROLE_PERMISSIONS: dict[UserRole, frozenset[Permission]] = {
    UserRole.ADMIN: frozenset(Permission),
    UserRole.MANAGER: frozenset({Permission.USERS_READ, Permission.METRICS_READ}),
    # Members act only on themselves and on what they own, which the /users/me
    # and owner-scoped item routes allow without any permission.
    UserRole.MEMBER: frozenset(),
}


def permissions_for(role: UserRole) -> frozenset[Permission]:
    """Fail closed: a role the matrix doesn't know grants nothing.

    Reachable if a row carries a role string this build has no member for, e.g.
    during a rollback. Denying beats raising a KeyError out of a dependency.
    """
    return ROLE_PERMISSIONS.get(role, frozenset())


def has_permission(role: UserRole, permission: Permission) -> bool:
    return permission in permissions_for(role)
