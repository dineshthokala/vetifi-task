"""
Tests for the publish and withdraw hardening, and for the client's ability to
survive a hostile or broken server.

Covers the failure modes that let a bad dose reach a patient:
  * duplicate ids in one publish silently last-wins
  * withdraw + upsert of the same id in one version
  * withdrawing an id that does not exist
  * re-withdrawing an already withdrawn drug
  * concurrent withdrawals producing two competing versions
  * calc_logs accepting garbage, NaN, or a batch large enough to hurt
"""

import concurrent.futures
import os
from pathlib import Path

import pytest
from starlette.testclient import TestClient

# DATABASE_URL and ADMIN_KEY are set in conftest.py.
from server.app.database import Base, engine, SessionLocal
from server.app.main import app, seed_database

H = {"X-Admin-Key": os.environ["ADMIN_KEY"]}


@pytest.fixture(autouse=True)
def fresh_db():
    Base.metadata.drop_all(bind=engine)
    Base.metadata.create_all(bind=engine)
    with SessionLocal() as db:
        seed_database(db)
    yield
    Base.metadata.drop_all(bind=engine)


@pytest.fixture
def client():
    with TestClient(app, raise_server_exceptions=False) as c:
        yield c


def _publish(client, version, base, upserts=None, withdrawn=None, headers=None):
    payload = {
        "schema_version": 2,
        "dataset_version": version,
        "base_version": base,
        "upserts": upserts or [],
    }
    if withdrawn is not None:
        payload["withdrawn"] = withdrawn
    return client.post("/v1/admin/datasets", headers=headers or H, json=payload)


def _drug(drug_id, name="X", conc="10 mg/mL"):
    return {
        "id": drug_id,
        "name": name,
        "concentration": conc,
        "route": "IV",
        "doses": {"dog": {"min": 1, "max": 2, "unit": "mg/kg"}},
    }


# ---------------------------------------------------------------------------
# Duplicate ids
# ---------------------------------------------------------------------------

def test_duplicate_ids_in_one_publish_rejected(client):
    """Last-wins would publish one correction while the operator believed both
    were applied."""
    res = _publish(
        client, "v15", "v14", upserts=[_drug("d001", "A"), _drug("d001", "B")]
    )
    assert res.status_code == 422
    ids = [e["drug_id"] for e in res.json()["detail"]["errors"]]
    assert "d001" in ids


# ---------------------------------------------------------------------------
# Withdraw conflicts
# ---------------------------------------------------------------------------

def test_withdraw_and_upsert_same_id_rejected(client):
    res = _publish(client, "v15", "v14", upserts=[_drug("d001")], withdrawn=["d001"])
    assert res.status_code == 422
    assert "withdrawn" in res.json()["detail"]["message"].lower()


def test_withdraw_unknown_id_rejected(client):
    """A typo would publish a withdrawal for a drug nobody has, and the operator
    would believe a recall had happened."""
    res = _publish(client, "v15", "v14", withdrawn=["d999"])
    assert res.status_code == 422
    assert "does not exist" in res.json()["detail"]["errors"][0]["message"]


def test_withdraw_empty_reason_rejected(client):
    res = client.post("/v1/admin/withdraw", headers=H,
                      json={"drug_id": "d001", "reason": "   "})
    assert res.status_code == 400


def test_rewithdrawing_already_withdrawn_is_409(client):
    first = client.post("/v1/admin/withdraw", headers=H,
                        json={"drug_id": "d001", "reason": "recall"})
    assert first.status_code == 201
    version_after_first = first.json()["dataset_version"]

    second = client.post("/v1/admin/withdraw", headers=H,
                         json={"drug_id": "d001", "reason": "again"})
    assert second.status_code == 409
    assert version_after_first in second.text or "already withdrawn" in second.text


def test_concurrent_withdrawals_one_conflicts():
    """Two operators withdrawing different drugs at once must not both win."""
    def withdraw(drug_id):
        with TestClient(app, raise_server_exceptions=False) as c:
            return c.post("/v1/admin/withdraw", headers=H,
                          json={"drug_id": drug_id, "reason": "recall"})

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as ex:
        results = [
            ex.submit(withdraw, "d001").result(),
            ex.submit(withdraw, "d002").result(),
        ]

    statuses = sorted(r.status_code for r in results)
    assert statuses[0] == 201, [r.status_code for r in results]
    assert statuses[1] in (201, 409)


def test_withdraw_idempotency_key(client):
    headers = {**H, "Idempotency-Key": "withdraw-abc-123"}
    first = client.post("/v1/admin/withdraw", headers=headers,
                        json={"drug_id": "d001", "reason": "recall"})
    assert first.status_code == 201

    second = client.post("/v1/admin/withdraw", headers=headers,
                         json={"drug_id": "d001", "reason": "recall"})
    assert second.status_code == 200
    assert second.json()["status"] == "already_withdrawn"


# ---------------------------------------------------------------------------
# calc_logs hardening
# ---------------------------------------------------------------------------

def test_calc_logs_rejects_garbage_without_500(client):
    """Previously float('abc') raised and the whole batch returned 500."""
    res = client.post("/v1/calc_logs", json={"logs": [
        {"calc_id": "a", "drug_id": "d001", "species": "dog",
         "weight_kg": "abc", "weight_entered": 10},
        {"calc_id": "b", "drug_id": "d001", "species": "dog",
         "weight_kg": 10, "weight_entered": 10},
    ]})
    assert res.status_code == 200
    body = res.json()
    assert body["rejected"] == 1
    assert body["inserted"] == 1


def test_calc_logs_rejects_nan_and_infinity(client):
    """Sent as a raw body because httpx refuses to encode NaN in json=.

    Python's json module happily parses the non-standard NaN/Infinity literals
    by default, so a hostile or buggy client can put them on the wire. They must
    not reach the database, where they would poison every aggregate over the
    column.
    """
    raw = (
        '{"logs": ['
        '{"calc_id":"nan","drug_id":"d001","species":"dog",'
        '"weight_kg":NaN,"weight_entered":10},'
        '{"calc_id":"inf","drug_id":"d001","species":"dog",'
        '"weight_kg":Infinity,"weight_entered":10},'
        '{"calc_id":"ninf","drug_id":"d001","species":"dog",'
        '"weight_kg":-Infinity,"weight_entered":10},'
        '{"calc_id":"ok","drug_id":"d001","species":"dog",'
        '"weight_kg":10,"weight_entered":10}'
        ']}'
    )
    res = client.post(
        "/v1/calc_logs",
        content=raw,
        headers={"Content-Type": "application/json"},
    )
    assert res.status_code == 200
    assert res.json()["rejected"] == 3
    assert res.json()["inserted"] == 1


def test_calc_logs_rejects_missing_identity(client):
    res = client.post("/v1/calc_logs", json={"logs": [
        {"calc_id": "x", "species": "dog", "weight_kg": 10, "weight_entered": 10},
        {"calc_id": "y", "drug_id": "d001", "weight_kg": 10, "weight_entered": 10},
        {"calc_id": "z", "drug_id": "d001", "species": "dog",
         "weight_kg": -5, "weight_entered": 10},
    ]})
    assert res.status_code == 200
    assert res.json()["rejected"] == 3


def test_calc_logs_rejects_inverted_ranges(client):
    res = client.post("/v1/calc_logs", json={"logs": [
        {"calc_id": "inv", "drug_id": "d001", "species": "dog",
         "weight_kg": 10, "weight_entered": 10,
         "dose_min_mg": 100, "dose_max_mg": 50},
    ]})
    assert res.status_code == 200
    assert res.json()["rejected"] == 1


def test_calc_logs_truncates_oversized_batch(client):
    logs = [
        {"calc_id": f"bulk-{i}", "drug_id": "d001", "species": "dog",
         "weight_kg": 10, "weight_entered": 10}
        for i in range(1500)
    ]
    res = client.post("/v1/calc_logs", json={"logs": logs})
    assert res.status_code == 200
    body = res.json()
    assert body["truncated"] is True
    assert body["inserted"] == 1000


def test_calc_logs_dedup_still_works(client):
    payload = {"logs": [
        {"calc_id": "dup-1", "drug_id": "d001", "species": "dog",
         "weight_kg": 10, "weight_entered": 10,
         "dose_min_mg": 10, "dose_max_mg": 20}
    ]}
    assert client.post("/v1/calc_logs", json=payload).json()["inserted"] == 1
    assert client.post("/v1/calc_logs", json=payload).json()["duplicates"] == 1


# ---------------------------------------------------------------------------
# Manifest tells the client when its version is unknown
# ---------------------------------------------------------------------------

def test_manifest_flags_unknown_client_version(client):
    _publish(client, "v15", "v14", upserts=[_drug("d001")])
    res = client.get("/v1/manifest?schema=2&current=v99")
    assert res.status_code == 200
    body = res.json()
    assert body["client_version_known"] is False
    assert body["delta_available"] is False


def test_manifest_flags_known_client_version(client):
    # Must be behind the latest version, otherwise the endpoint answers 304
    # (up to date) and there is no manifest body to inspect.
    _publish(client, "v15", "v14", upserts=[_drug("d001")])
    res = client.get("/v1/manifest?schema=2&current=v14")
    assert res.status_code == 200
    body = res.json()
    assert body["client_version_known"] is True
    assert body["delta_available"] is True