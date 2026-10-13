# Vetifi Round 1: Gap Review

Repo: `github.com/dineshthokala/vetifi-task`
Reviewed against: `Vetifi_Round1_Flutter_Assignment.pdf` / `assignment.txt`
Deadline: **Tuesday 13 Oct 2026, 11:59 pm IST**

## How this was reviewed

- Cloned the repo and read the full assignment text.
- Read the app's calculator, drug model, update service, sync service and database service, plus the server's main, validator, crypto, chaos, database and Docker files.
- **Ran the server test suite:** 68 passed.
- **Ran the server validator** against edge-case inputs. Findings marked *(verified)* come from that run.
- **Not run:** the Flutter app and its tests (no Flutter SDK available). App-side findings come from reading the code, so treat them as "very likely" rather than proven.
- I did not review Part G (code review answers) in detail.

---

## Priority checklist for tonight

| # | Task | Effort | Why |
|---|------|--------|-----|
| 1 | Record the video (max 5 min, unedited, face and screen visible) | 30 to 40 min | Required deliverable; README admits it is missing |
| 2 | Build and upload the release APK, and add its link | 15 min | Required deliverable; no APK in repo |
| 3 | Measure search latency on your real Android phone | 15 min | Part B.4 explicitly requires it |
| 4 | Fix validator gaps (NaN, bool, duplicate species) | 20 min | Server and app disagree on what is valid |
| 5 | Make withdraw `reason` required | 5 min | Brief says "with a reason" |
| 6 | Trim DECISIONS answers to 200 words or fewer | 10 min | Hard limit in the brief |
| 7 | Document the signing-key gap in Q5 and BREAK_IT | 10 min | Honest disclosure scores better than silence |
| 8 | Fix log-upload blocking and the 50k snapshot mismatch | 30 min | Real bugs, if time allows |

---

## 1. Missing deliverables

### 1.1 No video (Part H.4)
README states "No video." The brief requires up to 5 minutes, unedited, showing:
1. The app working in airplane mode.
2. The app online with the server in `CHAOS=1`, refusing a tampered update.
3. Finishing with the part of the work you are least confident about.

### 1.2 No APK link (Submission)
The submission email needs a GitHub link, an APK link and a video link. No APK exists in the repo.

**Related problem:** the release build's `network_security_config.xml` blocks cleartext HTTP except to `10.0.2.2`, `127.0.0.1` and `localhost`. On a real phone, updates will only work via:
- an emulator (`10.0.2.2`),
- `adb reverse tcp:8000 tcp:8000`, or
- an HTTPS deployment (also earns bonus credit).

State which one reviewers should use in the README.

### 1.3 Search latency not measured on a device (Part B.4)
The brief asks for typical and worst keystroke-to-results time on a real midrange Android phone, plus how you measured it. The README says this is "not yet measured on a physical device". Current numbers come from a Dart test on a dev machine.

**Fix:** measure on your own phone, record typical and worst values, describe the method, and update the README.

---

## 2. Design gap against the brief: signing key on the server

**Requirement (Part D):** "Someone who gains control of the server host or the network path must not be able to change a dose."

**What the code does:**
- `server/keys/private.hex` is committed to the repo.
- The Dockerfile copies it into the image.
- `sign_data()` signs every manifest and payload at request time.

**Result:**
- Network-path attackers are covered, because the app verifies Ed25519 signatures.
- Anyone who reads the repo, or controls the server host, can sign arbitrary doses that installed apps will accept.

**Proper fix (large):** sign offline at publish time with an admin tool; the server stores and serves signed artifacts and holds only the public key.

**Minimum for tonight:** say this plainly in DECISIONS Q5 and BREAK_IT as an unfixed issue you would not release with.

---

## 3. Server and app validators disagree *(verified)*

Running `validate_drug_entry` on edge cases, the server **accepts**:

| Input | Consequence |
|-------|-------------|
| `NaN` / `Infinity` in `min`, `max` or `max_total_mg` | Published JSON contains invalid tokens. Dart's `jsonDecode` rejects them, so clients cannot apply the version. Published versions are immutable. |
| `max_total_mg: true` | Python treats bool as a number. In the app, `(json['max_total_mg'] as num)` throws a `TypeError`. |
| `"Dog"` and `"dog"` both present with different doses | The app normalises both to `dog` and the last one silently wins. Neither side flags the conflict. |
| `doses: {}` or all-null doses | Accepted. The drug is unusable but publishes. |
| Concentration `1000%` or `0.0001 mg/mL` | No plausibility bound on either side. |
| Dose `1e308 mg/kg` | No upper bound on either side. |
| Arabic-Indic digits in concentration (`٥٠ mg/mL`) | Python `\d` plus `float()` accepts them; Dart `\d` does not. Minor, but literally drift. |

**App-side crash path:** in `update_service.dart`, `Drug.fromJson(entry)` runs outside any try/catch. A `TypeError` escapes. `SyncService` then catches it and reports it as "no network, working offline", which hides a real failure.

**Fixes:**
- In `validator.py`, parse with `parse_constant` to reject `NaN` / `Infinity`, reject `bool` for numeric fields, and error when two keys normalise to the same species.
- Add plausibility bounds (for example `%` ≤ 100, dose and concentration ceilings) on both sides.
- Wrap the `Drug.fromJson` loop in try/catch and return `UpdateStatus.malformed`.
- Add cases to `server/tests/test_contract.py` so drift fails a test.

---

## 4. Other server issues

1. **Withdraw reason is optional and fabricated.** `/v1/admin/withdraw` fills in "Withdrawn by regulatory authority" when no reason is given. The brief says "with a reason". Make it required (400 if missing).
2. **ETag is keyed only on the latest version.** The manifest content also depends on `current`. A conditional request from a client on an older version can wrongly get a 304. The app never sends `If-None-Match`, so the app does not exercise this path.
3. **Idempotency race.** The idempotency-key lookup runs before the row lock. A concurrent retry with the same key gets 409 instead of the original result. The replay response also has a different shape and status from the original (200 `already_published` versus 201). The same key with a different body silently returns the old result.
4. **Upsert silently reinstates a withdrawn drug.** There is no explicit "reinstate" operation. For a safety action like withdrawal, this deserves a deliberate design decision or a documented note.
5. **Duplicate `calc_id` inside one upload batch causes a 500.** With autoflush off, the per-item duplicate check does not see pending rows, so the commit raises an integrity error for the whole batch.
6. **Tests run on SQLite only.** `conftest.py` forces SQLite, where `FOR UPDATE` is a no-op. `docker compose up` runs Postgres. All 68 tests pass, but the Postgres concurrency path that actually ships is untested. SQLite is acceptable per the brief; adding a Postgres run would be stronger.
7. **Postgres port 5432 is published** with a default password (`vetifi_local_password`). Fine for local demo; mention it or drop the port mapping.
8. **`X-Force-Chaos` works without `CHAOS=1`.** Any caller can force a tampered or error response for their own request. Low impact; worth a one-line mention.

---

## 5. App issues

1. **Log upload can block forever.** `uploadCalcLogs` only marks logs uploaded if `inserted + duplicates >= logs.length`. If the server rejects one row, the app marks nothing, breaks, and resends the same batch next time. The bad row stays at the head of the queue and uploads stop.
   - **Fix:** have the server return rejected ids; the app marks them uploaded or quarantines them.
2. **Full snapshot wipes the 50k generated entries.** The app's "v14" is 10 drugs plus 50,000 generated entries. The server's v14 seed has only the 10. Any full-snapshot fallback (client version unknown, combined delta unavailable) deletes everything the snapshot omits, so the catalogue shrinks to about 10 with no notice. Two datasets also carry the same version label.
   - **Fix:** put the generated entries in the server's v14 as well (the brief says to add them to the base dataset), or document and handle it.
3. **Weight plausibility is not species-specific.** One advisory band (1 to 60 kg) for both species, and a hard limit of 1500 kg. A "40 kg cat" or "500 kg dog" is accepted. The brief says impossible values must be rejected.
   - **Fix:** per-species hard limits.
4. **`1,200` parses as 1.2 kg.** The code comment says thousands separators are guarded, but the code only checks for more than one `.` after replacing commas.
   - **Fix:** reject ambiguous comma/dot combinations.
5. **Number parsing leniency (unverified).** Test whether Dart's `double.tryParse` lets `1e2` or hex forms through `parseWeight`.
6. **Dev-server probing left in production code.** `_ensureServerUrl` tries `127.0.0.1`, `10.0.2.2` and `192.168.1.7`. In release builds the LAN address is blocked by the network config anyway, so it is dead code. Remove it and rely on the Settings URL.

---

## 6. Written answers (Part F)

Word counts, excluding the heading and markdown symbols. The limit is 200 words each, and the README claims "under 200".

| Question | Words | Status |
|----------|-------|--------|
| Q1 Small doses | ~211 | Over |
| Q2 Missing species data | ~202 | Over |
| Q3 Bag volume | ~177 | OK |
| Q4 Users who never update | ~196 | OK |
| Q5 Leaked signing key | ~201 | Over |
| Q6 Limits of the design | ~203 | Over |

Trim Q1, Q2, Q5 and Q6. Q4's staleness banner is implemented in `home_screen.dart`, so the answer matches the code.

**Q5 note:** make sure it states that the signing key lives on the server and that host compromise allows forged doses (see section 2). The brief says it will check that the code matches the answers.

---

## 7. What is solid

- **Dose maths:** the bolus and CRI formulas have correct units and derivations. The CRI formula carries both the 60 min/hr and 1000 mcg/mg factors.
- **Refusals:** zero concentration, inverted ranges, null species, unknown units and sub-measurable volumes are refused rather than rounded.
- **Species keys:** `Dog` and `feline` are normalised.
- **`max_total_mg`:** the cap is applied.
- **Updates:** signature, SHA-256, schema, version-match and anti-rollback checks are all required. The app applies each update in one SQLite transaction, with the version metadata written inside it.
- **Server:** combined deltas, a row lock plus unique constraint giving 409 on concurrent publish, idempotency keys, and field-level 422 errors. The v15 to v18 test cases are handled as intended.
- **Tests:** 68 server tests pass; the repo also ships app tests and a CHAOS mode with all four failure types.
- **Honesty:** the README already lists omissions (video, device measurement, revocation list). Closing the items above makes it stronger.

---

## 8. Suggested additions to BREAK_IT.md

Name at least one issue you did not fix and say whether you would release anyway. Good candidates:
- Signing key resident on the server (section 2): **would not release**.
- Missing species-specific weight limits (section 5.3).
- Plausibility bounds on concentration and dose (section 3).
