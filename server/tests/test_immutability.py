"""
Guarantees the properties of published dataset versions that the brief
requires but that are otherwise only implied by the absence of an endpoint:

  * "Published versions cannot be modified."
  * Publishing from a stale base is a 409, not a silent fork.
  * Re-publishing the same idempotency key returns the original result.

Immutability is enforced structurally: there is no PUT, PATCH or DELETE route
anywhere in the application, and a new version can only ever be an INSERT. This
file asserts both the routing and the database-level consequences, so the
property fails a test if someone later adds a mutating endpoint.
"""

import json
import os
from pathlib import Path

from starlette.testclient import TestClient

from server.app.database import Base, CalculationLog, DatasetVersion, SessionLocal, engine
from server.app.main import app, seed_database

ADMIN = {"X-Admin-Key": os.environ["ADMIN_KEY"]}
SEED = Path(__file__).resolve().parent.parent / "seed"


def _reset():
    Base.metadata.drop_all(bind=engine)
    Base.metadata.create_all(bind=engine)
    with SessionLocal() as db:
        seed_database(db)


def test_no_endpoint_can_modify_a_published_version():
    """
    The strongest form of "cannot be modified": there is no mutating route.

    Asserted against the live routing table, not by reading the source, so
    adding a PATCH would fail here rather than being discovered in production.
    """
    mutating = {"PUT", "PATCH", "DELETE"}
    routes = [
        (method, route.path)
        for route in app.routes
        for method in getattr(route, "methods", set())
    ]

    offenders = [
        f"{method} {path}" for method, path in routes if method in mutating
    ]
    assert not offenders, f"mutating dataset endpoints exist: {offenders}"

    # And no route mentions a version in a way that could rewrite one.
    version_writes = [
        f"{method} {path}"
        for method, path in routes
        if "/v1/datasets/" in path and method not in {"GET"}
    ]
    assert not version_writes, f"a dataset version route accepts writes: {version_writes}"


def test_republishing_the_same_content_does_not_change_a_version():
    """A version's stored bytes and signature are stable over time."""
    _reset()
    with TestClient(app) as c:
        before = c.get("/v1/datasets/v14")
        payload_before = before.text
        sha_before = before.headers["x-sha256"]

        # Publish several later versions.
        v15 = json.loads((SEED / "update_v15.json").read_text())
        assert c.post("/v1/admin/datasets", headers=ADMIN, json=v15).status_code == 201
        c.post("/v1/admin/withdraw", headers=ADMIN,
               json={"drug_id": "d003", "reason": "recall"})

        after = c.get("/v1/datasets/v14")
        assert after.text == payload_before, "v14 changed after later publishes"
        assert after.headers["x-sha256"] == sha_before

    Base.metadata.drop_all(bind=engine)


def test_a_stale_base_is_rejected_rather_than_forking():
    """
    Two publishes from v14 must not both succeed, even with different version
    numbers. Only the unique version_num constraint would stop the same-number
    case; a differing-number fork has to be refused by the base_version check.
    """
    _reset()
    with TestClient(app) as c:
        first = {
            "schema_version": 2,
            "dataset_version": "v15",
            "base_version": "v14",
            "upserts": [{
                "id": "d001", "name": "One", "concentration": "10 mg/mL",
                "route": "IV", "doses": {"dog": {"min": 1, "max": 2, "unit": "mg/kg"}},
            }],
        }
        second = {
            "schema_version": 2,
            "dataset_version": "v16",  # different number, same stale base
            "base_version": "v14",
            "upserts": [{
                "id": "d002", "name": "Two", "concentration": "20 mg/mL",
                "route": "IV", "doses": {"dog": {"min": 1, "max": 2, "unit": "mg/kg"}},
            }],
        }

        assert c.post("/v1/admin/datasets", headers=ADMIN, json=first).status_code == 201
        second_res = c.post("/v1/admin/datasets", headers=ADMIN, json=second)
        assert second_res.status_code == 409, (
            "a publish from a stale base must be refused, otherwise two "
            "datasets both claim to descend from v14"
        )

        with SessionLocal() as db:
            versions = sorted(
                v.version for v in db.query(DatasetVersion).all()
            )
        assert versions == ["v14", "v15"], f"unexpected history: {versions}"

    Base.metadata.drop_all(bind=engine)


def test_a_version_cannot_be_reissued_with_different_content():
    _reset()
    with TestClient(app) as c:
        v15 = json.loads((SEED / "update_v15.json").read_text())
        assert c.post("/v1/admin/datasets", headers=ADMIN, json=v15).status_code == 201

        # Same version number, different content, current base.
        conflict = {
            "schema_version": 2,
            "dataset_version": "v15",
            "base_version": "v15",
            "upserts": [{
                "id": "d001", "name": "Rewritten", "concentration": "999 mg/mL",
                "route": "IV", "doses": {"dog": {"min": 1, "max": 2, "unit": "mg/kg"}},
            }],
        }
        res = c.post("/v1/admin/datasets", headers=ADMIN, json=conflict)
        assert res.status_code == 409

        # The original v15 is untouched.
        assert "Rewritten" not in c.get("/v1/datasets/v15").text

    Base.metadata.drop_all(bind=engine)


def test_withdrawal_creates_a_new_version_rather_than_editing_the_old_one():
    _reset()
    with TestClient(app) as c:
        v14_before = c.get("/v1/datasets/v14").text
        assert c.post(
            "/v1/admin/withdraw", headers=ADMIN,
            json={"drug_id": "d001", "reason": "recall"},
        ).status_code == 201

        assert c.get("/v1/datasets/v14").text == v14_before
        assert c.get("/health").json()["latest_dataset_version"] == "v15"

    Base.metadata.drop_all(bind=engine)


def test_idempotent_republish_returns_the_original_result_not_a_new_version():
    _reset()
    v15 = json.loads((SEED / "update_v15.json").read_text())
    headers = {**ADMIN, "Idempotency-Key": "stable-key-42"}

    with TestClient(app) as c:
        first = c.post("/v1/admin/datasets", headers=headers, json=v15)
        assert first.status_code == 201
        original = first.json()

        second = c.post("/v1/admin/datasets", headers=headers, json=v15)
        assert second.status_code == 200
        assert second.json()["dataset_version"] == original["dataset_version"]
        assert second.json()["sha256"] == original["sha256"]

        with SessionLocal() as db:
            assert db.query(DatasetVersion).filter_by(version="v15").count() == 1

    Base.metadata.drop_all(bind=engine)


def test_calculation_logs_are_append_only_too():
    """A re-uploaded record must not overwrite the first one."""
    _reset()
    record = {
        "calc_id": "immutable-log-1",
        "drug_id": "d001", "drug_name": "Veloxamine", "species": "dog",
        "weight_kg": 20.0, "weight_unit": "kg", "weight_entered": 20.0,
        "dose_min_mg": 100.0, "dose_max_mg": 200.0,
        "volume_min_ml": 2.0, "volume_max_ml": 4.0,
        "dataset_version": "v14", "timestamp": "2026-10-13T00:00:00Z",
    }
    with TestClient(app) as c:
        assert c.post("/v1/calc_logs", json={"logs": [record]}).json()["inserted"] == 1

        # Same id, different numbers: must be treated as a duplicate.
        tampered = {**record, "volume_max_ml": 999.0}
        res = c.post("/v1/calc_logs", json={"logs": [tampered]})
        assert res.json()["duplicates"] == 1
        assert res.json()["inserted"] == 0

        with SessionLocal() as db:
            row = db.query(CalculationLog).filter_by(calc_id="immutable-log-1").one()
            # The original recorded 4.0 mL; the duplicate claimed 999.0 and
            # must not have overwritten it.
            assert row.volume_max_ml == 4.0, "a duplicate upload overwrote the original"

    Base.metadata.drop_all(bind=engine)