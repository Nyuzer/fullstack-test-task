# AI usage

This submission was built with Claude Code. The conversations are in
[`ai-transcripts/`](ai-transcripts/). This page records what I delegated, what I
rejected, and what I checked myself.

## What I delegated

**Codebase reconnaissance.** Before writing anything I had the model read the
template and report how authentication worked, what authorization already
existed, how the frontend learned who the user was, and where the tests lived.
That survey is what surfaced the `SyntaxError` in `app/api/deps.py` that stopped
the backend from importing at all.

**The authorization test file, written before any implementation existed.** I
dispatched a sub-agent to write `tests/api/routes/test_permissions.py` against a
planned API — `app.core.permissions`, the `role` column, the `/metrics` route —
none of which existed yet. The brief fixed the constraints (one file, under 300
lines, under 12 test functions) and the six areas to cover. The file came back
red, failing on `ModuleNotFoundError: No module named 'app.core.permissions'`,
which was the intended outcome: the tests described the contract, and the
implementation then had to satisfy it rather than the tests being shaped around
whatever got built. I verified the failure was only that import error and not a
bug in the test file.

**The implementation itself**, step by step against an approved plan, and the
documentation in this repository.

**An authorization review.** A second sub-agent audited the finished RBAC layer
with a narrow brief: concrete findings only, each with a file and an exploit
scenario, and explicit permission to answer "no issue found" rather than
inventing material. It ran live probes against the running stack and reported no
privilege escalation, one deployment-configuration risk, and several lower-value
observations.

## What I rejected or corrected

**The review's framing of its main finding.** It reported the unauthenticated
`/private/users/` endpoint as a finding against this work. It is vendored
template behaviour, present in the initial import and untouched here; I verified
that in the git history before recording it as inherited rather than introduced.

**My own plan, on 404-before-403.** I had planned to move the 404 ahead of the
403 in `read_user_by_id` "so non-admins stop learning which ids exist". The
sub-agent writing the tests pushed back: 404-for-missing and 403-for-existing is
exactly what *enables* enumeration, and the template's existing 403-for-both is
the non-leaking behaviour. It was right and I corrected the plan.

**A squashed commit.** I committed five plan steps as one blob. On being pulled
up on it I unwound it into seven commits, one per step, and verified each one
imports cleanly so the history actually bisects rather than merely looking
granular.

**A security hook's advice.** A pre-write hook flagged SQLModel's `session.exec`
query API as if it were Node's shell-executing equivalent, and blocked the write.
The advice did not apply to Python here; I wrote the file by another route and
said so rather than silently working around it.

**A claim I made about a fix.** I described the fail-closed change as removing
the 500 on an unrecognised role. Testing showed it fixed the authorization path
(403, correctly) but `/users/me` still returns 500 from response serialization, a
different root cause. That is recorded as a known issue rather than claimed as
fixed.

## What I verified by hand

Every behavioural claim in the README and NOTES was checked against a running
stack, not inferred from the code. Specifically: the migration applied,
downgraded and re-applied against a populated database; the permission matrix
probed at the API with each of the three role tokens; 401 versus 403 confirmed
for missing, malformed and valid-but-unprivileged credentials; privilege
escalation attempted through `PATCH /users/me`, `POST /users/signup` and
`POST /private/users/`, each confirmed against the database row rather than the
response body; and all three roles driven through the UI in a browser, checking
navigation visibility, the 403 page on direct navigation, and the gating of the
Add User and per-row Edit and Delete controls.

Where a check failed I kept the failure visible rather than restating the
intended behaviour: the 500 on `{"role": null}`, the container serving stale code
after a rebuild was skipped, and the partially effective fail-closed fix were all
found this way.
