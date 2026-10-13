"""
End-to-end check that the app and the server agree.

The unit tests prove the app rejects bad payloads and that the server rejects
bad publishes. Neither proves the two agree on the *bytes*: that the payload
the server signs is the payload the app would accept, that withdrawals survive
the round trip, and that a multi-version delta actually merges.

This exercises the real server in-process and re-runs the app's decision tree
against its real responses. The signature check is reimplemented in Python
rather than imported, so a bug in the Dart verifier cannot make this pass.
"""

import hashlib
import json
import os
from pathlib import Path

import pytest
from starlette.testclient import TestClient

from server.app.database import Base, SessionLocal, engine
from server.app.main import app, seed_database

ADMIN = {"X-Admin-Key": os.environ["ADMIN_KEY"]}
SEED = Path(__file__).resolve().parent.parent / "seed"
REPO_ROOT = Path(__file__).resolve().parents[2]
PUBLIC_KEY_HEX = (REPO_ROOT / "server" / "keys" / "public.hex").read_text().strip()


def sha256(data: str) -> str:
    return hashlib.sha256(data.encode("utf-8")).hexdigest()


def verify_sig(data: str, signature_hex: str) -> bool:
    """An independent reimplementation of the app's signature check."""
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

    try:
        key = Ed25519PublicKey.from_public_bytes(bytes.fromhex(PUBLIC_KEY_HEX))
        key.verify(bytes.fromhex(signature_hex), data.encode("utf-8"))
        return True
    except Exception:
        return False


def app_accepts(client: TestClient, current: str) -> tuple[bool, str]:
    """
    Mirrors UpdateService.checkForUpdate -> downloadAndApply.

    Returns (would_apply, reason).
    """
    m = client.get(f"/v1/manifest?schema=2&current={current}")
    if m.status_code == 304:
        return False, "up to date"
    if m.status_code != 200:
        return False, f"manifest HTTP {m.status_code}"

    if not verify_sig(m.text, m.headers.get("x-signature", "")):
        return False, "manifest signature rejected"

    manifest = m.json()
    latest = manifest["latest_version"]
    expected_hash = manifest["sha256"]

    # A client the server does not recognise must fall back to a snapshot
    # rather than loop on a delta that will 404.
    if manifest.get("client_version_known", True) and manifest.get("delta_available"):
        url = f"/v1/datasets/{latest}?from={current}"
    else:
        url = f"/v1/datasets/{latest}"

    r = client.get(url)
    if r.status_code != 200:
        return False, f"dataset HTTP {r.status_code} for {url}"

    if sha256(r.text) != expected_hash:
        return False, "sha256 mismatch"

    header_sha = r.headers.get("x-sha256")
    if header_sha and header_sha != sha256(r.text):
        return False, "header sha disagreement"

    sig = r.headers.get("x-signature") or manifest.get("signature")
    if not verify_sig(r.text, sig or ""):
        return False, "payload signature rejected"

    data = json.loads(r.text)
    if data.get("schema_version") != 2:
        return False, "schema mismatch"
    if data.get("dataset_version") != latest:
        return False, "version mismatch"

    return True, f"would apply {latest}"


@pytest.fixture
def client():
    Base.metadata.drop_all(bind=engine)
    Base.metadata.create_all(bind=engine)
    with SessionLocal() as db:
        seed_database(db)
    with TestClient(app) as c:
        yield c
    Base.metadata.drop_all(bind=engine)


def latest_version(client: TestClient) -> str:
    """Read the server's current head rather than assuming a version number."""
    return client.get("/health").json()["latest_dataset_version"]


def test_uptodate_client_does_nothing(client):
    assert app_accepts(client, "v14") == (False, "up to date")


def test_legitimate_publish_is_accepted_end_to_end(client):
    v15 = json.loads((SEED / "update_v15.json").read_text())
    assert client.post("/v1/admin/datasets", headers=ADMIN, json=v15).status_code == 201

    ok, why = app_accepts(client, "v14")
    assert ok, f"a valid v15 update should be accepted by the app: {why}"


def test_client_on_the_new_version_is_up_to_date(client):
    v15 = json.loads((SEED / "update_v15.json").read_text())
    client.post("/v1/admin/datasets", headers=ADMIN, json=v15)

    ok, why = app_accepts(client, "v15")
    assert not ok
    assert why == "up to date"


def test_unknown_client_version_falls_back_to_a_snapshot(client):
    """The manifest previously advertised an update the client could not
    fetch: ?from=v99 returned 404 forever."""
    v15 = json.loads((SEED / "update_v15.json").read_text())
    client.post("/v1/admin/datasets", headers=ADMIN, json=v15)

    ok, why = app_accepts(client, "v99")
    assert ok, f"an unknown client version must still be able to sync: {why}"


def test_withdrawal_survives_the_round_trip(client):
    client.post(
        "/v1/admin/withdraw", headers=ADMIN,
        json={"drug_id": "d002", "reason": "Batch recall 2026-10"},
    )
    head = latest_version(client)

    ok, why = app_accepts(client, "v14")
    assert ok, why

    payload = client.get(f"/v1/datasets/{head}?from=v14").json()
    assert "d002" in payload["withdrawn"]
    assert payload["withdrawn_reasons"]["d002"] == "Batch recall 2026-10"


def test_multi_version_delta_merges_every_withdrawal(client):
    client.post("/v1/admin/withdraw", headers=ADMIN,
                json={"drug_id": "d002", "reason": "Recall 2"})
    client.post("/v1/admin/withdraw", headers=ADMIN,
                json={"drug_id": "d001", "reason": "Recall 1"})
    head = latest_version(client)

    ok, why = app_accepts(client, "v14")
    assert ok, why

    payload = client.get(f"/v1/datasets/{head}?from=v14").json()
    assert {"d001", "d002"} <= set(payload["withdrawn"])


def test_chaos_tampered_payload_fails_signature(client):
    r = client.get("/v1/datasets/v14", headers={"X-Force-Chaos": "tampered"})
    assert not verify_sig(r.text, r.headers.get("x-signature", ""))


def test_chaos_bad_checksum_is_detected(client):
    r = client.get("/v1/datasets/v14", headers={"X-Force-Chaos": "bad_checksum"})
    assert r.headers["x-sha256"] != sha256(r.text)


def test_chaos_truncated_payload_is_not_valid_json(client):
    r = client.get("/v1/datasets/v14", headers={"X-Force-Chaos": "truncated"})
    with pytest.raises(json.JSONDecodeError):
        json.loads(r.text)


def test_chaos_server_error_is_an_http_error(client):
    r = client.get("/v1/datasets/v14", headers={"X-Force-Chaos": "server_error"})
    assert r.status_code == 500


def test_published_dopraxine_is_computable_by_the_app_vocabulary(client):
    """Dopraxine arrives in v15 and the app must be able to use its CRI data."""
    v15 = json.loads((SEED / "update_v15.json").read_text())
    client.post("/v1/admin/datasets", headers=ADMIN, json=v15)

    snapshot = client.get("/v1/datasets/v15").json()
    d011 = next((d for d in snapshot["drugs"] if d["id"] == "d011"), None)
    assert d011 is not None, "Dopraxine missing from the published snapshot"
    assert d011["cri"]["dog"]["unit"] == "mcg/kg/min"
    assert d011["concentration"] == "40 mg/mL"