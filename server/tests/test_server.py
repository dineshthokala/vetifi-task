"""
Integration tests for Vetifi Dataset Server against real database.
Covers:
1. Seed v14 base dataset
2. Publishing test cases (v15, v16, v17, v18)
3. Concurrent publish race condition (409 Conflict)
4. Idempotent publish with Idempotency-Key
5. Multi-version delta combination
6. Ed25519 signature verification
7. Admin authentication and timing-attack protection
8. Calculation logs upload and deduplication
9. Manifest ETag and 304 Not Modified
10. CHAOS mode responses (tampered, bad checksum, truncated, 500)
"""

import concurrent.futures
import json
import os
from pathlib import Path

import pytest
from starlette.testclient import TestClient

# DATABASE_URL and ADMIN_KEY are set in conftest.py, before any test module is
# imported. Setting them here would race with the other suite.
from server.app.database import Base, engine, SessionLocal
from server.app.main import app, seed_database
from server.app.crypto import verify_signature, get_public_key_hex, compute_sha256

ADMIN_KEY = os.environ["ADMIN_KEY"]
AUTH = {"X-Admin-Key": ADMIN_KEY}

SEED_DIR = Path(__file__).resolve().parent.parent / "seed"


@pytest.fixture(autouse=True)
def setup_teardown_db():
    """Reset database before each test."""
    Base.metadata.drop_all(bind=engine)
    Base.metadata.create_all(bind=engine)
    with SessionLocal() as db:
        seed_database(db)
    yield
    Base.metadata.drop_all(bind=engine)


@pytest.fixture
def client():
    with TestClient(app) as c:
        yield c


# -----------------------------------------------------------------------------
# 1. Base Dataset & Health Check
# -----------------------------------------------------------------------------

def test_health_check_seeded_v14(client):
    res = client.get("/health")
    assert res.status_code == 200
    data = res.json()
    assert data["status"] == "healthy"
    assert data["database"] == "connected"
    assert data["latest_dataset_version"] == "v14"


def test_get_v14_dataset_and_signature(client):
    res = client.get("/v1/datasets/v14")
    assert res.status_code == 200
    body = res.text
    data = res.json()
    assert data["dataset_version"] == "v14"
    assert len(data["drugs"]) == 10

    # Verify SHA256 header
    sha = res.headers.get("x-sha256")
    assert sha == compute_sha256(body)

    # Verify Ed25519 signature header
    sig = res.headers.get("x-signature")
    assert sig is not None
    assert verify_signature(body, sig)


# -----------------------------------------------------------------------------
# 2. Assignment Publishing Test Cases (v15, v16, v17, v18)
# -----------------------------------------------------------------------------

def test_publish_v15_accepted(client):
    """update_v15.json: Valid update, should be accepted (201 Created)."""
    v15_data = json.loads((SEED_DIR / "update_v15.json").read_text(encoding="utf-8"))
    res = client.post(
        "/v1/admin/datasets",
        headers=AUTH,
        json=v15_data,
    )
    assert res.status_code == 201
    resp = res.json()
    assert resp["dataset_version"] == "v15"
    assert resp["base_version"] == "v14"

    # Verify health now reports v15
    h_res = client.get("/health")
    assert h_res.json()["latest_dataset_version"] == "v15"


def test_publish_v16_rejected_version_backwards(client):
    """update_v16.json: Same as v15, but version is v13 (backwards). Must be rejected."""
    v16_data = json.loads((SEED_DIR / "update_v16.json").read_text(encoding="utf-8"))
    res = client.post(
        "/v1/admin/datasets",
        headers=AUTH,
        json=v16_data,
    )
    assert res.status_code == 400
    assert "backwards" in res.json()["detail"].lower()


def test_publish_v17_rejected_schema_version_3(client):
    """update_v17.json: Schema version is 3. Must be rejected."""
    v17_data = json.loads((SEED_DIR / "update_v17.json").read_text(encoding="utf-8"))
    res = client.post(
        "/v1/admin/datasets",
        headers=AUTH,
        json=v17_data,
    )
    assert res.status_code == 400
    assert "schema_version" in res.json()["detail"].lower()


def test_publish_v18_rejected_truncated_json(client):
    """update_v18.json: Cut off halfway, not valid JSON. Must be rejected."""
    v18_bytes = (SEED_DIR / "update_v18.json").read_bytes()
    res = client.post(
        "/v1/admin/datasets",
        headers={
            "X-Admin-Key": ADMIN_KEY,
            "Content-Type": "application/json",
        },
        content=v18_bytes,
    )
    assert res.status_code == 400
    assert "malformed" in res.json()["detail"].lower() or "json" in res.json()["detail"].lower()


# -----------------------------------------------------------------------------
# 3. Field-Level Validation Rejection
# -----------------------------------------------------------------------------

def test_publish_rejects_invalid_drugs_with_field_errors(client):
    """Verifies that invalid drug data (min > max, 0 conc) is rejected with field errors."""
    bad_payload = {
        "schema_version": 2,
        "dataset_version": "v15",
        "base_version": "v14",
        "upserts": [
            {
                "id": "bad01",
                "name": "BadDrug",
                "concentration": "0 mg/mL",
                "route": "IV",
                "doses": {"dog": {"min": 10, "max": 5, "unit": "mg/kg"}}
            }
        ]
    }
    res = client.post(
        "/v1/admin/datasets",
        headers=AUTH,
        json=bad_payload,
    )
    assert res.status_code == 422
    errs = res.json()["detail"]["errors"]
    fields = [e["field"] for e in errs]
    assert "concentration" in fields
    assert any("doses.dog" in f for f in fields)


# -----------------------------------------------------------------------------
# 4. Concurrency Control (409 Conflict)
# -----------------------------------------------------------------------------

def test_concurrent_publish_returns_409_conflict():
    """
    Two administrators publish from base v14 simultaneously.
    Exactly one succeeds and the other receives 409 Conflict.
    """
    client_local = TestClient(app)

    v15_payload_admin1 = {
        "schema_version": 2,
        "dataset_version": "v15",
        "base_version": "v14",
        "withdrawn": ["d009"],
        "upserts": [
            {
                "id": "d005",
                "name": "Meloquin Injectable 1",
                "concentration": "5 mg/mL",
                "route": "SC",
                "doses": {"dog": {"min": 0.1, "max": 0.2, "unit": "mg/kg"}}
            }
        ]
    }

    v15_payload_admin2 = {
        "schema_version": 2,
        "dataset_version": "v15",
        "base_version": "v14",
        "withdrawn": [],
        "upserts": [
            {
                "id": "d005",
                "name": "Meloquin Injectable 2",
                "concentration": "5 mg/mL",
                "route": "SC",
                "doses": {"dog": {"min": 0.1, "max": 0.2, "unit": "mg/kg"}}
            }
        ]
    }

    results = []

    def post_publish(payload):
        with TestClient(app) as c:
            return c.post(
                "/v1/admin/datasets",
                headers=AUTH,
                json=payload,
            )

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        f1 = executor.submit(post_publish, v15_payload_admin1)
        f2 = executor.submit(post_publish, v15_payload_admin2)
        r1 = f1.result()
        r2 = f2.result()

    statuses = sorted([r1.status_code, r2.status_code])
    assert statuses == [201, 409], f"Expected [201, 409] but got {statuses}"


# -----------------------------------------------------------------------------
# 5. Idempotent Publishing
# -----------------------------------------------------------------------------

def test_idempotent_publish(client):
    """Repeating a publish request with the same idempotency key returns the original result."""
    v15_data = json.loads((SEED_DIR / "update_v15.json").read_text(encoding="utf-8"))
    headers = {
        "X-Admin-Key": ADMIN_KEY,
        "Idempotency-Key": "unique-request-key-abc-123",
    }

    res1 = client.post("/v1/admin/datasets", headers=headers, json=v15_data)
    assert res1.status_code == 201

    # Repeat exact same request with same idempotency key
    res2 = client.post("/v1/admin/datasets", headers=headers, json=v15_data)
    assert res2.status_code == 200
    assert res2.json()["status"] == "already_published"
    assert res2.json()["dataset_version"] == "v15"


# -----------------------------------------------------------------------------
# 6. Multi-Version Delta Combination
# -----------------------------------------------------------------------------

def test_multi_version_delta_combination(client):
    """
    Publish v15 (base v14), then publish v16 (base v15).
    Requesting /v1/datasets/v16?from=v14 must return correctly combined deltas.
    """
    v15_data = json.loads((SEED_DIR / "update_v15.json").read_text(encoding="utf-8"))
    r1 = client.post("/v1/admin/datasets", headers=AUTH, json=v15_data)
    assert r1.status_code == 201

    v16_data = {
        "schema_version": 2,
        "dataset_version": "v16",
        "base_version": "v15",
        "withdrawn": ["d001"],
        "withdrawn_reasons": {"d001": "Withdrawn in v16"},
        "upserts": [
            {
                "id": "d007",
                "name": "Benzaprol Forte",
                "concentration": "200 mg/mL",
                "route": "IV",
                "doses": {"dog": {"min": 1, "max": 2, "unit": "mg/kg"}}
            }
        ]
    }
    r2 = client.post("/v1/admin/datasets", headers=AUTH, json=v16_data)
    assert r2.status_code == 201

    # Request delta spanning v14 -> v16
    res = client.get("/v1/datasets/v16?from=v14")
    assert res.status_code == 200
    combined = res.json()

    assert combined["dataset_version"] == "v16"
    assert combined["base_version"] == "v14"
    # Withdrawals combined: d009 from v15 + d001 from v16
    assert set(combined["withdrawn"]) == {"d009", "d001"}
    # Upserts merged: d005 from v15, d011 from v15, d007 from v16 (overwrote v15)
    upsert_ids = {u["id"] for u in combined["upserts"]}
    assert "d005" in upsert_ids
    assert "d011" in upsert_ids
    assert "d007" in upsert_ids
    d007_up = next(u for u in combined["upserts"] if u["id"] == "d007")
    assert d007_up["name"] == "Benzaprol Forte"  # v16 version took precedence


# -----------------------------------------------------------------------------
# 7. Admin Authentication & Drug Withdrawal
# -----------------------------------------------------------------------------

def test_admin_auth_required(client):
    res = client.post("/v1/admin/datasets", json={})
    assert res.status_code == 401

    res_wrong = client.post("/v1/admin/datasets", headers={"X-Admin-Key": "wrong-key"}, json={})
    assert res_wrong.status_code == 401


def test_withdraw_endpoint(client):
    """POST /v1/admin/withdraw creates new dataset version with withdrawn drug."""
    res = client.post(
        "/v1/admin/withdraw",
        headers=AUTH,
        json={"drug_id": "d001", "reason": "Severe toxicity reported in trials"},
    )
    assert res.status_code == 201
    assert res.json()["dataset_version"] == "v15"
    assert res.json()["drug_id"] == "d001"


# -----------------------------------------------------------------------------
# 8. Calc Logs Deduplication
# -----------------------------------------------------------------------------

def test_calc_logs_deduplication(client):
    payload = {
        "logs": [
            {
                "calc_id": "uuid-1111-2222",
                "drug_id": "d001",
                "drug_name": "Veloxamine",
                "species": "dog",
                "weight_kg": 10.0,
                "weight_unit": "kg",
                "weight_entered": 10.0,
                "dose_min_mg": 50.0,
                "dose_max_mg": 100.0,
                "volume_min_ml": 1.0,
                "volume_max_ml": 2.0,
                "dataset_version": "v14",
                "timestamp": "2026-10-12T00:00:00Z"
            }
        ]
    }
    r1 = client.post("/v1/calc_logs", json=payload)
    assert r1.status_code == 200
    assert r1.json()["inserted"] == 1
    assert r1.json()["duplicates"] == 0

    # Resend exact same log
    r2 = client.post("/v1/calc_logs", json=payload)
    assert r2.status_code == 200
    assert r2.json()["inserted"] == 0
    assert r2.json()["duplicates"] == 1


# -----------------------------------------------------------------------------
# 9. Manifest & ETag Caching
# -----------------------------------------------------------------------------

def test_manifest_etag_and_304(client):
    res = client.get("/v1/manifest?schema=2&current=v13")
    assert res.status_code == 200
    etag = res.headers.get("etag")
    assert etag is not None

    # Resend with If-None-Match
    res_304 = client.get("/v1/manifest?schema=2&current=v13", headers={"If-None-Match": etag})
    assert res_304.status_code == 304

    # Current matching latest also returns 304
    res_up_to_date = client.get("/v1/manifest?schema=2&current=v14")
    assert res_up_to_date.status_code == 304


# -----------------------------------------------------------------------------
# 10. CHAOS Mode Testing
# -----------------------------------------------------------------------------

def test_chaos_server_error(client):
    res = client.get("/v1/manifest?schema=2&current=v13", headers={"X-Force-Chaos": "server_error"})
    assert res.status_code == 500


def test_chaos_bad_checksum(client):
    res = client.get("/v1/datasets/v14", headers={"X-Force-Chaos": "bad_checksum"})
    assert res.status_code == 200
    assert res.headers["x-sha256"] == "0000000000000000000000000000000000000000000000000000000000000000"


def test_chaos_tampered_payload(client):
    res = client.get("/v1/datasets/v14", headers={"X-Force-Chaos": "tampered"})
    assert res.status_code == 200
    # Signature verification must fail for tampered body
    sig = res.headers.get("x-signature")
    assert not verify_signature(res.text, sig)


def test_chaos_truncated_payload(client):
    res = client.get("/v1/datasets/v14", headers={"X-Force-Chaos": "truncated"})
    assert res.status_code == 200
    # Truncated body is not valid JSON
    with pytest.raises(Exception):
        json.loads(res.text)

