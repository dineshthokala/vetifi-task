"""
Vetifi Dataset Server — FastAPI application.
Handles dataset publishing, atomic deltas, Ed25519 signing,
calculation log collection, ETag caching, and CHAOS testing mode.
"""

import hmac
import json
import os
import re
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, Response, status
from fastapi.responses import JSONResponse
from sqlalchemy.orm import Session
from sqlalchemy.exc import IntegrityError

from .chaos import ChaosMiddleware
from .crypto import compute_sha256, get_public_key_hex, sign_data
from .database import CalculationLog, DatasetVersion, SessionLocal, get_db, init_db
from .validator import parse_version_number, validate_drug_entry


ADMIN_KEY_ENV_VAR = "ADMIN_KEY"


def _require_admin_key() -> str:
    """
    Reads ADMIN_KEY from the environment, refusing to start without one.

    A hardcoded fallback would mean every deployment that forgot to set the
    variable shares the same key, and that key would be published in this
    repository. Failing closed is the only safe default for an endpoint that can
    change a dose.
    """
    key = os.environ.get(ADMIN_KEY_ENV_VAR, "").strip()
    if not key:
        raise RuntimeError(
            f"{ADMIN_KEY_ENV_VAR} is not set. Set it to a random value, for example:\n"
            "  docker compose up  (reads it from docker-compose.yml)\n"
            "  export ADMIN_KEY=$(python -c 'import secrets;print(secrets.token_urlsafe(32))')\n"
            "  uvicorn server.app.main:app"
        )
    return key


SEED_DIR = Path(__file__).resolve().parent.parent / "seed"


def seed_database(db: Session):
    """Seed v14 base dataset if database is empty."""
    existing = db.query(DatasetVersion).filter_by(version="v14").first()
    if existing:
        return

    v14_path = SEED_DIR / "v14.json"
    if not v14_path.exists():
        return

    v14_text = v14_path.read_text(encoding="utf-8")
    v14_data = json.loads(v14_text)

    # Normalize serialization
    canonical_json = json.dumps(v14_data, sort_keys=True)
    sha = compute_sha256(canonical_json)
    sig = sign_data(canonical_json)

    v14_entry = DatasetVersion(
        version="v14",
        version_num=14,
        base_version=None,
        schema_version=v14_data.get("schema_version", 2),
        payload_json=canonical_json,
        delta_json=None,
        sha256=sha,
        signature=sig,
    )
    db.add(v14_entry)
    db.commit()


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Fail fast at startup rather than on the first publish attempt.
    _require_admin_key()
    init_db()
    with SessionLocal() as db:
        seed_database(db)
    yield


app = FastAPI(
    title="Vetifi Dataset Server",
    version="1.0.0",
    description="Dataset publishing and sync server for Vetifi veterinary dose calculator",
    lifespan=lifespan,
)

# Attach CHAOS testing middleware
app.add_middleware(ChaosMiddleware)


def verify_admin_key(x_admin_key: str | None = Header(None, alias="X-Admin-Key")):
    """
    Authenticates an admin request.

    The expected key is read from the environment on each request rather than
    captured at import time, so the key can be rotated by restarting with a new
    value, and so tests can set it independently of module import order.

    Compared with hmac.compare_digest so the comparison time does not leak how
    much of the key was guessed correctly.
    """
    expected = os.environ.get(ADMIN_KEY_ENV_VAR, "").strip()
    if not expected:
        # Misconfiguration must never behave like a valid key.
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Admin API is not configured",
        )
    if not x_admin_key:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing X-Admin-Key header")
    if not hmac.compare_digest(x_admin_key, expected):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid admin credentials")
    return x_admin_key


# -----------------------------------------------------------------------------
# Public endpoints
# -----------------------------------------------------------------------------

@app.get("/health")
def health_check(db: Session = Depends(get_db)):
    """Health check reporting database status and latest dataset version."""
    try:
        latest = db.query(DatasetVersion).order_by(DatasetVersion.version_num.desc()).first()
        version = latest.version if latest else "none"
        return {
            "status": "healthy",
            "database": "connected",
            "latest_dataset_version": version,
            "public_key": get_public_key_hex(),
        }
    except Exception as e:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=f"Database error: {e}")


@app.get("/v1/manifest")
def get_manifest(
    request: Request,
    schema: int = Query(2, description="Client schema version"),
    current: str = Query("v14", description="Client current dataset version"),
    db: Session = Depends(get_db),
):
    """
    Returns latest dataset manifest, indicating if updates or deltas are available.
    Supports ETag (returns 304 if unchanged).
    """
    if schema != 2:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Unsupported schema version")

    latest = db.query(DatasetVersion).order_by(DatasetVersion.version_num.desc()).first()
    if not latest:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="No dataset versions found")

    # The manifest content depends on both ends of the sync: the payload hash,
    # delta availability and sha all vary with `current`. Keying the ETag on
    # the latest version alone lets a conditional request from a client on an
    # older version wrongly match and receive a 304 for content it never saw.
    etag = f'"{latest.version}:{current}"'
    if request.headers.get("if-none-match") == etag:
        return Response(status_code=status.HTTP_304_NOT_MODIFIED)

    if current == latest.version:
        # Client already on latest version
        return Response(
            status_code=status.HTTP_304_NOT_MODIFIED,
            headers={"ETag": etag}
        )

    # Determine delta availability
    delta_available = False
    payload_to_serve = latest.payload_json
    client_version_known = True

    base_record = db.query(DatasetVersion).filter_by(version=current).first()
    if base_record is None:
        # We have never heard of this client's version. It cannot receive a
        # delta, and asking for one would 404 forever. Say so explicitly so the
        # client falls back to a full snapshot rather than retrying.
        client_version_known = False
        payload_to_serve = latest.payload_json
    elif current:
        # Check if direct delta or combinable delta exists
        if latest.delta_json and latest.base_version == current:
            delta_available = True
            payload_to_serve = latest.delta_json
        elif base_record.version_num < latest.version_num:
            # Combined delta possible
            combined = build_combined_delta(db, current, latest.version)
            if combined:
                delta_available = True
                payload_to_serve = json.dumps(combined, sort_keys=True)

    sha = compute_sha256(payload_to_serve)
    sig = sign_data(payload_to_serve)

    manifest_data = {
        "schema_version": latest.schema_version,
        "latest_version": latest.version,
        "current_version": current,
        "delta_available": delta_available,
        # Tells a client whose version we do not recognise to fetch the full
        # snapshot instead of a delta.
        "client_version_known": client_version_known,
        "payload_size": len(payload_to_serve.encode("utf-8")),
        "sha256": sha,
        "signature": sig,
    }

    manifest_json = json.dumps(manifest_data, sort_keys=True)
    manifest_sig = sign_data(manifest_json)

    return Response(
        content=manifest_json,
        media_type="application/json",
        headers={
            "ETag": etag,
            "X-SHA256": compute_sha256(manifest_json),
            "X-Signature": manifest_sig,
        },
    )


@app.get("/v1/datasets/{version}")
def get_dataset(
    version: str,
    from_base: str | None = Query(None, alias="from", description="Base version for delta"),
    db: Session = Depends(get_db),
):
    """
    Returns full dataset snapshot or delta update from base version.
    Signed with Ed25519 and includes SHA256 header.
    """
    target = db.query(DatasetVersion).filter_by(version=version).first()
    if not target:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Version '{version}' not found")

    # If from_base requested, attempt delta
    payload_str: str | None = None
    if from_base:
        if from_base == target.version:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="from and target versions are identical")

        base_record = db.query(DatasetVersion).filter_by(version=from_base).first()
        if not base_record:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Base version '{from_base}' not found")

        if base_record.version_num > target.version_num:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="from version is newer than requested version")

        # Check for direct delta
        if target.base_version == from_base and target.delta_json:
            payload_str = target.delta_json
        else:
            # Combine intermediate deltas
            combined = build_combined_delta(db, from_base, target.version)
            if combined:
                payload_str = json.dumps(combined, sort_keys=True)

    # Fallback to full snapshot if delta not requested or not possible
    if payload_str is None:
        payload_str = target.payload_json

    sha = compute_sha256(payload_str)
    sig = sign_data(payload_str)

    return Response(
        content=payload_str,
        media_type="application/json",
        headers={
            "ETag": f'"{version}"',
            "X-SHA256": sha,
            "X-Signature": sig,
        },
    )


def build_combined_delta(db: Session, from_ver: str, to_ver: str) -> dict[str, Any] | None:
    """
    Combines intermediate deltas from from_ver up to to_ver.
    - Unions withdrawn lists
    - Merges upserts (later version overwrites earlier version of same drug ID)
    - If a drug was upserted then later withdrawn, it is withdrawn.
    """
    from_record = db.query(DatasetVersion).filter_by(version=from_ver).first()
    to_record = db.query(DatasetVersion).filter_by(version=to_ver).first()
    if not from_record or not to_record:
        return None

    # Get all versions strictly between from_record and to_record inclusive
    versions = (
        db.query(DatasetVersion)
        .filter(DatasetVersion.version_num > from_record.version_num, DatasetVersion.version_num <= to_record.version_num)
        .order_by(DatasetVersion.version_num.asc())
        .all()
    )

    combined_withdrawn: set[str] = set()
    combined_withdrawn_reasons: dict[str, str] = {}
    combined_upserts: dict[str, dict[str, Any]] = {}

    for v in versions:
        if not v.delta_json:
            # Cannot build pure delta if intermediate version lacks delta
            return None
        delta = json.loads(v.delta_json)

        # Process withdrawals
        for w_id in delta.get("withdrawn", []):
            combined_withdrawn.add(w_id)
            if w_id in combined_upserts:
                del combined_upserts[w_id]

        for w_id, reason in delta.get("withdrawn_reasons", {}).items():
            combined_withdrawn_reasons[w_id] = reason

        # Process upserts
        for up in delta.get("upserts", []):
            u_id = up["id"]
            if u_id in combined_withdrawn:
                combined_withdrawn.remove(u_id)
            combined_upserts[u_id] = up

    return {
        "schema_version": to_record.schema_version,
        "dataset_version": to_record.version,
        "base_version": from_ver,
        "withdrawn": sorted(list(combined_withdrawn)),
        "withdrawn_reasons": combined_withdrawn_reasons,
        "upserts": list(combined_upserts.values()),
    }


# -----------------------------------------------------------------------------
# Admin endpoints
# -----------------------------------------------------------------------------

@app.post("/v1/admin/datasets", status_code=status.HTTP_201_CREATED)
async def publish_dataset(
    request: Request,
    admin_key: str = Depends(verify_admin_key),
    idempotency_key: str | None = Header(None, alias="Idempotency-Key"),
    db: Session = Depends(get_db),
):
    """
    Publishes a new dataset version.
    Validates entries, ensures idempotency, and enforces concurrency control.
    """
    if idempotency_key is None:
        idempotency_key = request.headers.get("X-Idempotency-Key")

    # 1. Idempotency check: if key already exists, return previous result
    if idempotency_key:
        existing_idempotent = db.query(DatasetVersion).filter_by(idempotency_key=idempotency_key).first()
        if existing_idempotent:
            return JSONResponse(
                content={
                    "status": "already_published",
                    "dataset_version": existing_idempotent.version,
                    "sha256": existing_idempotent.sha256,
                    "signature": existing_idempotent.signature,
                },
                status_code=status.HTTP_200_OK,
            )

    # 2. Parse request body (handle malformed JSON like update_v18)
    #
    # Non-standard NaN/Infinity literals are rejected at the door: Python's
    # json parses them into floats the validator would otherwise have to catch
    # one field at a time, and Dart's jsonDecode rejects the tokens outright,
    # so they could never survive the round trip to a client.
    def _reject_constant(value: str):
        raise ValueError(f"Non-standard JSON constant not allowed: {value}")

    try:
        raw_body = await request.body()
        body = json.loads(raw_body.decode("utf-8"), parse_constant=_reject_constant)
    except Exception as e:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Malformed JSON in request body: {e}"
        )

    if not isinstance(body, dict):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Request body must be a JSON object")

    # 3. Schema version validation (update_v17 test case)
    schema_ver = body.get("schema_version")
    if schema_ver != 2:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Unsupported schema_version {schema_ver}. Only schema_version 2 is supported."
        )

    # Fetch current latest version.
    #
    # Locked. Without this, two publishes can both read latest=v14, both pass
    # the base_version check, and both insert: the unique constraint on
    # version_num turns the loser into a 409, but that only works because both
    # chose the same version number. If they chose different ones the fork
    # would be published silently, leaving two datasets that both claim to
    # descend from v14.
    latest = (
        db.query(DatasetVersion)
        .order_by(DatasetVersion.version_num.desc())
        .with_for_update()
        .first()
    )

    # 4. Base version & concurrency conflict check (409 Conflict)
    base_version = body.get("base_version")
    if latest:
        if base_version is None:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="base_version is required for updates")
        if base_version != latest.version:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=f"Conflict: base_version '{base_version}' does not match current latest version '{latest.version}'"
            )

    # 5. Dataset version syntax & monotonicity (update_v16 test case)
    new_version_str = body.get("dataset_version")
    if not new_version_str or not isinstance(new_version_str, str):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Missing dataset_version")

    try:
        new_version_num = parse_version_number(new_version_str)
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))

    if latest:
        if new_version_num < latest.version_num:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Version cannot go backwards. Current is {latest.version}, submitted {new_version_str}"
            )
        if new_version_num == latest.version_num:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=f"Conflict: version '{new_version_str}' already exists"
            )

    # Check if this version already exists
    if db.query(DatasetVersion).filter_by(version=new_version_str).first():
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"Conflict: version '{new_version_str}' already exists"
        )

    # 6. Validate every drug entry in upserts (or drugs for full snapshot)
    upserts = body.get("upserts", body.get("drugs", []))
    if not isinstance(upserts, list):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="'upserts' must be a list")

    # Duplicate IDs in one payload. The last one would silently win, so an
    # operator merging two corrections would publish one of them and believe
    # both were applied. Refuse instead.
    seen_ids: set[str] = set()
    duplicate_ids: set[str] = set()
    for drug in upserts:
        if isinstance(drug, dict):
            did = drug.get("id")
            if isinstance(did, str):
                if did in seen_ids:
                    duplicate_ids.add(did)
                seen_ids.add(did)
    if duplicate_ids:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={
                "message": "Duplicate drug ids within a single publish",
                "errors": [
                    {
                        "drug_id": drug_id,
                        "field": "id",
                        "message": f"{drug_id} appears more than once in this version",
                    }
                    for drug_id in sorted(duplicate_ids)
                ],
            },
        )

    validation_errors: list[dict[str, str]] = []
    for drug in upserts:
        if not isinstance(drug, dict):
            validation_errors.append({"drug_id": "UNKNOWN", "field": "entry", "message": "Drug entry must be an object"})
            continue
        errors = validate_drug_entry(drug)
        validation_errors.extend(errors)

    if validation_errors:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={"message": "Validation failed for one or more drug entries", "errors": validation_errors}
        )

    # 7. Build full dataset snapshot from base version snapshot + upserts + withdrawn
    withdrawn = body.get("withdrawn", [])
    if not isinstance(withdrawn, list) or any(not isinstance(w, str) for w in withdrawn):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="'withdrawn' must be a list of drug id strings")
    withdrawn_set = set(withdrawn)

    # A payload that withdraws and upserts the same drug in one version is
    # ambiguous: the two operations disagree about whether the drug should be
    # usable. Refuse it rather than letting field order decide.
    overlap = withdrawn_set & {d.get("id") for d in upserts if isinstance(d, dict)}
    if overlap:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={
                "message": "A drug cannot be withdrawn and upserted in the same version",
                "errors": [
                    {
                        "drug_id": drug_id,
                        "field": "withdrawn",
                        "message": f"{drug_id} appears in both 'withdrawn' and 'upserts'",
                    }
                    for drug_id in sorted(overlap)
                ],
            },
        )

    if latest:
        base_data = json.loads(latest.payload_json)
        existing_drugs = {d["id"]: d for d in base_data.get("drugs", [])}
    else:
        existing_drugs = {}

    # Withdrawing an id that is not in the dataset is almost always a typo. The
    # published version would carry a withdrawal for a drug nobody has, and the
    # operator would believe a drug had been recalled when it had not.
    unknown_withdrawals = sorted(withdrawn_set - set(existing_drugs) - {d["id"] for d in upserts if isinstance(d, dict)})
    if unknown_withdrawals:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={
                "message": "Cannot withdraw a drug that is not in the dataset",
                "errors": [
                    {
                        "drug_id": drug_id,
                        "field": "withdrawn",
                        "message": f"{drug_id} does not exist in the current dataset",
                    }
                    for drug_id in unknown_withdrawals
                ],
            },
        )

    # Apply withdrawals
    for w_id in withdrawn_set:
        if w_id in existing_drugs:
            existing_drugs[w_id]["is_withdrawn"] = True
            existing_drugs[w_id]["withdrawn_reason"] = body.get("withdrawn_reasons", {}).get(w_id, "Withdrawn by administrator")

    # Apply upserts
    for drug in upserts:
        existing_drugs[drug["id"]] = drug

    new_full_snapshot = {
        "schema_version": 2,
        "dataset_version": new_version_str,
        "drugs": list(existing_drugs.values()),
    }

    full_json_str = json.dumps(new_full_snapshot, sort_keys=True)
    full_sha = compute_sha256(full_json_str)
    full_sig = sign_data(full_json_str)

    delta_json_str = json.dumps(body, sort_keys=True)

    new_version_record = DatasetVersion(
        version=new_version_str,
        version_num=new_version_num,
        base_version=base_version,
        schema_version=2,
        payload_json=full_json_str,
        delta_json=delta_json_str,
        sha256=full_sha,
        signature=full_sig,
        idempotency_key=idempotency_key,
    )

    try:
        db.add(new_version_record)
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Concurrent publish conflict")

    return {
        "status": "published",
        "dataset_version": new_version_str,
        "base_version": base_version,
        "sha256": full_sha,
        "signature": full_sig,
    }


@app.post("/v1/admin/withdraw", status_code=status.HTTP_201_CREATED)
def withdraw_drug(
    body: dict[str, Any],
    admin_key: str = Depends(verify_admin_key),
    idempotency_key: str | None = Header(None, alias="Idempotency-Key"),
    db: Session = Depends(get_db),
):
    """
    Withdraws a drug with a reason, published as a new dataset version.

    Carries the same concurrency and idempotency guarantees as
    POST /v1/admin/datasets, because a withdrawal is a safety action: two
    operators withdrawing different drugs at the same time must not silently
    produce two competing versions.
    """
    drug_id = body.get("drug_id")
    reason = body.get("reason")

    if not drug_id or not isinstance(drug_id, str):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Missing drug_id")

    # A withdrawal with no reason leaves the clinician unable to tell a recall
    # from a deprecation from a data-entry error, which is exactly the
    # information they need at the moment they refuse to calculate. The brief
    # requires a reason, so it is required here rather than fabricated: a
    # server-invented reason would present an operator's silence as a
    # regulator's statement.
    if not isinstance(reason, str) or not reason.strip():
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="'reason' is required and must be a non-empty string",
        )
    reason = reason.strip()

    # Idempotency: a retried request returns the original result rather than
    # creating a second, identical version.
    if idempotency_key:
        existing = db.query(DatasetVersion).filter_by(idempotency_key=idempotency_key).first()
        if existing:
            return JSONResponse(
                content={
                    "status": "already_withdrawn",
                    "dataset_version": existing.version,
                    "sha256": existing.sha256,
                    "signature": existing.signature,
                },
                status_code=status.HTTP_200_OK,
            )

    latest = (
        db.query(DatasetVersion)
        .order_by(DatasetVersion.version_num.desc())
        .with_for_update()
        .first()
    )
    if not latest:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="No base dataset exists")

    base_data = json.loads(latest.payload_json)
    drugs = base_data.get("drugs", [])

    target = next((d for d in drugs if d.get("id") == drug_id), None)
    if target is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Drug '{drug_id}' not found in current dataset",
        )

    if target.get("is_withdrawn"):
        # Already withdrawn. Re-publishing would bump the version for no reason
        # and force every client to re-sync.
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                f"Drug '{drug_id}' is already withdrawn in {latest.version}"
                + (f": {target.get('withdrawn_reason')}" if target.get("withdrawn_reason") else "")
            ),
        )

    next_ver_num = latest.version_num + 1
    next_ver_str = f"v{next_ver_num}"

    delta_payload = {
        "schema_version": 2,
        "dataset_version": next_ver_str,
        "base_version": latest.version,
        "withdrawn": [drug_id],
        "withdrawn_reasons": {drug_id: reason},
        "upserts": [],
    }

    target["is_withdrawn"] = True
    target["withdrawn_reason"] = reason

    new_snapshot = {
        "schema_version": 2,
        "dataset_version": next_ver_str,
        "drugs": drugs,
    }

    full_json_str = json.dumps(new_snapshot, sort_keys=True)
    full_sha = compute_sha256(full_json_str)
    full_sig = sign_data(full_json_str)
    delta_json_str = json.dumps(delta_payload, sort_keys=True)

    new_version_record = DatasetVersion(
        version=next_ver_str,
        version_num=next_ver_num,
        base_version=latest.version,
        schema_version=2,
        payload_json=full_json_str,
        delta_json=delta_json_str,
        sha256=full_sha,
        signature=full_sig,
        idempotency_key=idempotency_key,
    )

    db.add(new_version_record)
    try:
        db.commit()
    except IntegrityError:
        # Another withdrawal published from the same base first.
        db.rollback()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"Concurrent withdrawal conflict: {latest.version} is no longer the latest version",
        )

    return {
        "status": "withdrawn",
        "dataset_version": next_ver_str,
        "drug_id": drug_id,
        "reason": reason,
        "sha256": full_sha,
        "signature": full_sig,
    }


# -----------------------------------------------------------------------------
# Calculation logs endpoint
# -----------------------------------------------------------------------------

@app.post("/v1/calc_logs", status_code=status.HTTP_200_OK)
def receive_calc_logs(body: dict[str, Any], db: Session = Depends(get_db)):
    """
    Accepts calculation logs uploaded by the app.

    Deduplicates on calc_id so a retried upload after a dropped connection does
    not double-count a calculation.

    The endpoint is deliberately unauthenticated, because the app may be in the
    field with no credentials and the data is not clinically authoritative. It is
    therefore treated as untrusted input: every field is range-checked and a
    malformed record is skipped rather than allowed to raise. An earlier version
    called float() on unchecked input, so a single bad row returned a 500 and
    discarded the whole batch.
    """
    logs_raw = body.get("logs", [])
    if isinstance(body, list):
        logs_raw = body
    elif "calc_id" in body:
        logs_raw = [body]

    if not isinstance(logs_raw, list):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="'logs' must be a list")

    # Bound the batch so one device cannot exhaust memory.
    max_batch = 1000
    truncated = len(logs_raw) > max_batch
    if truncated:
        logs_raw = logs_raw[:max_batch]

    inserted = 0
    duplicates = 0
    rejected = 0
    # Ids the server refused, returned so the client can retire them instead
    # of resending the same bad row forever. Rows rejected before an id is
    # known (not an object, blank calc_id) are counted but have nothing to
    # report, so the list can be shorter than the count.
    rejected_ids: list[str] = []
    seen_in_batch: set[str] = set()

    def as_float(value: Any, *, low: float, high: float, default: float) -> float | None:
        if value is None:
            return default
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return None
        f = float(value)
        # NaN fails every comparison, including x == x is False. Testing that
        # first is what rejects it; the range check then rejects +/-inf.
        if f != f:
            return None
        if f < low or f > high:
            return None
        return f

    for item in logs_raw:
        if not isinstance(item, dict):
            rejected += 1
            continue
        calc_id = item.get("calc_id")
        if not calc_id or not isinstance(calc_id, str) or not calc_id.strip():
            rejected += 1
            continue
        calc_id = calc_id.strip()[:64]

        # A duplicate inside one batch never reaches the per-row database
        # check below (autoflush is off, so pending rows are invisible to it)
        # and used to die as a 500 on commit for the whole batch. Count it as
        # a duplicate up front instead.
        if calc_id in seen_in_batch:
            duplicates += 1
            continue
        seen_in_batch.add(calc_id)

        # A log must identify a real drug and carry a positive weight and a
        # non-negative dose; anything else is corrupt or hostile.
        drug_id = item.get("drug_id")
        species = item.get("species")
        weight_kg = as_float(item.get("weight_kg"), low=0.0, high=1500.0, default=-1.0)
        weight_entered = as_float(item.get("weight_entered"), low=0.0, high=100000.0, default=-1.0)
        dose_min_mg = as_float(item.get("dose_min_mg"), low=0.0, high=1e7, default=0.0)
        dose_max_mg = as_float(item.get("dose_max_mg"), low=0.0, high=1e7, default=0.0)
        volume_min_ml = as_float(item.get("volume_min_ml"), low=0.0, high=1e6, default=0.0)
        volume_max_ml = as_float(item.get("volume_max_ml"), low=0.0, high=1e6, default=0.0)

        if (
            not drug_id
            or not species
            or weight_kg is None
            or weight_kg <= 0
            or weight_entered is None
            or weight_entered <= 0
        ):
            rejected += 1
            rejected_ids.append(calc_id)
            continue

        if dose_max_mg and dose_min_mg > dose_max_mg:
            rejected += 1
            rejected_ids.append(calc_id)
            continue
        if volume_max_ml and volume_min_ml > volume_max_ml:
            rejected += 1
            rejected_ids.append(calc_id)
            continue

        existing = db.query(CalculationLog).filter_by(calc_id=calc_id).first()
        if existing:
            duplicates += 1
            continue

        optional_float_fields = {
            "dose_rate": as_float(item.get("dose_rate"), low=0.0, high=1e6, default=None),
            "fluid_rate_ml_hr": as_float(item.get("fluid_rate_ml_hr"), low=0.0, high=1e6, default=None),
            "bag_size_ml": as_float(item.get("bag_size_ml"), low=0.0, high=1e6, default=None),
            "ml_to_add": as_float(item.get("ml_to_add"), low=0.0, high=1e6, default=None),
            "bag_duration_hrs": as_float(item.get("bag_duration_hrs"), low=0.0, high=1e6, default=None),
        }

        timestamp = item.get("timestamp")
        db.add(CalculationLog(
            calc_id=calc_id,
            drug_id=str(drug_id)[:64],
            drug_name=str(item.get("drug_name", "UNKNOWN"))[:128],
            species=str(species)[:32],
            weight_kg=weight_kg,
            weight_unit=str(item.get("weight_unit", "kg"))[:16],
            weight_entered=weight_entered,
            dose_min_mg=dose_min_mg or 0.0,
            dose_max_mg=dose_max_mg or 0.0,
            volume_min_ml=volume_min_ml or 0.0,
            volume_max_ml=volume_max_ml or 0.0,
            dataset_version=str(item.get("dataset_version", "unknown"))[:32],
            timestamp=str(timestamp)[:64] if timestamp else "",
            **optional_float_fields,
        ))
        inserted += 1

    db.commit()

    return {
        "status": "success",
        "inserted": inserted,
        "duplicates": duplicates,
        "rejected": rejected,
        "rejected_ids": rejected_ids,
        "truncated": truncated,
    }
