# Vetifi — Veterinary Dose Calculator & Dataset Sync

Round 1 submission, Vetifi Technologies (SDE Intern, Flutter).

An offline-first dose calculator for small-animal clinicians, plus a signed
dataset service so corrections reach a device without an app release.

> All drug names and doses are fictional. **Not for clinical use.**

---

## Quick start

### Server

```bash
export ADMIN_KEY=$(python -c "import secrets;print(secrets.token_urlsafe(32))")
cd server && docker compose up --build
```

That is the entire setup: PostgreSQL 16 with a health check, the FastAPI
service, and the `v14` seed loaded on first boot. `ADMIN_KEY` has **no
default** — the server refuses to start without it, because a hardcoded
fallback would mean any deployment that forgot to set it shares a published key
on an endpoint that can change a dose.

Check it:

```bash
curl -s localhost:8000/health
# {"status":"healthy","database":"connected","latest_dataset_version":"v14", ...}
```

Without Docker:

```bash
pip install -r server/requirements.txt
export ADMIN_KEY=dev
uvicorn server.app.main:app --port 8000      # run from the repository root
```

### App

```bash
cd app
flutter pub get
flutter run
```

The dataset server defaults to `http://10.0.2.2:8000`, which is the host machine
as seen from an Android emulator. For a physical device on the same LAN, change
the base URL in **Settings** (or pass a host the app can reach).

### Tests

```bash
cd app     && flutter test                            # 128 tests
cd server  && python -m pytest server/tests -q        # 61 tests
```

---

## What was built

| Part | Status | Notes |
|---|---|---|
| **A. Dose calculator** | Complete | Offline, refusal-first, handles every trap in the shipped dataset |
| **B. Search** | Complete | 50,000-entry corpus, typo-tolerant, runs off the UI isolate |
| **C. CRI** | Complete | Formula derived from units; dilution and dose-rate range handled |
| **D. Dataset server** | Complete | Ed25519, deltas, 409 on conflict, idempotency, CHAOS mode |
| **E. Updates in the app** | Complete | Mandatory verification, atomic apply, log upload |
| **F. Written questions** | Complete | All six, under 200 words each, each backed by a test |
| **G. Code review** | Complete | All three functions, ranked by harm |
| **H. Documentation** | Partial | README, DECISIONS, BREAK_IT, AI_LOG. **No video.** |

### Deliberately not built

- **No video.** The brief asks for up to 5 minutes. Not produced; the scripted
  equivalent is the manual procedure in BREAK_IT.md section 2.
- **No peer-to-peer device sync.** Analysed in DECISIONS.md question 4 — it
  needs its own threat model for propagating signed data over an ad-hoc radio.
- **No signed revocation list.** This is the change that would make key
  rotation survivable without an app release, and it is the highest-value thing
  we would build next (DECISIONS.md question 5).

These are the only omissions we consider material. Everything in the table above
is implemented and tested.

---

## Architecture

```
 app/                          Flutter, offline-first
   lib/services/
     dose_calculator.dart      Pure functions. No I/O, no network. Tested as such.
     search_index.dart         Trigram + bounded-Levenshtein index, runs in an isolate
     update_service.dart       Verify-then-apply. Verification is mandatory.
     database_service.dart     SQLite. One transaction per update.
     sync_service.dart         Connectivity-gated sync, reports outcomes
   lib/models/drug.dart        Parsing + validation. Unit vocabulary shared with the server

 server/                       FastAPI, SQLAlchemy
   app/main.py                 Endpoints, concurrency, deltas
   app/validator.py            Field-level validation. Vocabulary shared with the app
   app/crypto.py               Ed25519 signing
   app/chaos.py                Four required failure modes, plus X-Force-Chaos
```

### Three properties the design leans on

**1. A calculation cannot reach the network.** `DoseCalculator` imports no I/O,
no database, no HTTP. `update_security_test.dart` asserts this structurally, so
the property holds even if a future edit adds a call. The same input always
produces the same answer, on a plane or on wifi.

**2. Verification is mandatory, not conditional.** An earlier version checked
signatures with `if (signature != null)`, which meant an attacker who could
strip a header bypassed verification entirely. Now a missing signature is a
rejection. The app also requires the payload's declared version to match the
manifest's, so an old but validly signed payload cannot be filed under a newer
label.

**3. The app and server cannot drift on what is computable.** Both accept
exactly `mg/kg` and `mcg/kg` for bolus doses and `mcg/kg/min` for CRI.
`server/tests/test_contract.py` parses the Dart constants and asserts they
match the Python ones, so changing one without the other is a test failure.

---

## Measured performance

Part B asks for keystroke-to-results latency on a real midrange Android phone,
and for an explanation of how it was measured. Here is what we can actually
evidence, and what we cannot.

**Measured, reproducible** — `flutter test test/search_test.dart` over the full
50,000-entry corpus, four consecutive runs on the development machine:

| | median | p95 | worst |
|---|---|---|---|
| run 1 | 0.37 ms | 1.10 ms | 3.10 ms |
| run 2 | 0.40 ms | 1.22 ms | 4.02 ms |
| run 3 | 0.42 ms | 1.38 ms | 3.54 ms |
| run 4 | 0.80 ms | 1.47 ms | 4.45 ms |

The spread is GC pauses on a desktop host, not algorithmic variance — the
median moves by 2× across runs while the shape of the distribution does not.
The number to quote is the p95: **under 1.5 ms, worst case under 5 ms.**

A test asserts the 95th percentile and the worst case both fit inside one 60 Hz
frame (16.7 ms), so a future regression to O(n²) fails the build rather than
quietly dropping frames.

**How it is measured.** `test/search_test.dart` builds a `SearchIndex` from the
same 50,000 entries shipped in the APK, warms it with 60 queries so JIT
compilation is not counted as typical latency, then times 300 searches across a
set covering every stage of the funnel (exact, prefix, substring, approximate,
and no-match). `tool/bench_search.dart` runs the same benchmark standalone and
prints a per-query breakdown, which is how the pathological cases were found
and fixed.

**Not yet measured on a physical device.** We have not run this on real
midrange hardware, so we cannot give you a trustworthy device figure. What that
leaves unmeasured is the isolate hop and the SQLite re-read of the result rows.
On a device expect the search itself to be roughly 3–5× slower. **A measurement
on real hardware is the one piece of Part B we would want to add before
shipping**, and it is the only Part B requirement we consider outstanding.

The first version of this search ran Levenshtein across every row on the UI
isolate on every keystroke. The benchmark caught it at a 30 ms worst case; the
trigram index and prefix arrays brought it under 5 ms. Both numbers are in the
git history, because the regression is the interesting part.

---

## Notable engineering decisions

**A full snapshot is authoritative; a delta is not.** When the app receives a
snapshot it deletes rows the snapshot omits. When it receives a delta it does
not — omitting a row from a delta is ambiguous, and treating it as a delete
would turn one truncated delta into mass unavailability.

**Withdrawal state round-trips.** An earlier version parsed drug entries without
reading `is_withdrawn`, so any client that received a full snapshot instead of a
delta had every withdrawn drug silently reinstated. The flag now survives the
full parse → JSON → SQLite path, and there is a test for it.

**Sub-measurable volumes are refused, not rounded.** A required volume of
0.00001 mL is an error, not `0.000 mL`. A displayed number reads as an
instruction.

**Out-of-range CRI rates are computed *and* flagged.** A vet may have a
legitimate reason to exceed the validated range; refusing removes the
information they need. The flag states the multiple of the approved maximum.

**`ADMIN_KEY` has no default and `INTERNET` was missing from the release
manifest.** Both were bugs we found by auditing our own submission. The first
meant a misconfigured deployment was an open one; the second meant the release
APK could not make a single network request, so Parts D and E were dead in the
shipped build. Both are fixed and both were invisible to the tests that existed
at the time.

---

## Repository layout

```
/app                 Flutter application
/server              FastAPI dataset server
  keys/              Signing keypair (private.hex is committed for the demo)
  seed/              v14 base dataset and the v15-v18 publishing test cases
  tests/             50 tests
  Dockerfile, docker-compose.yml
README.md            This file
DECISIONS.md         Part F answers and Part G review
BREAK_IT.md          Failure modes, defences, and what we did not fix
AI_LOG.md            AI usage, including where it was wrong
```

---

## Further reading

- **DECISIONS.md** — the six written questions and the code review. Each answer
  names the test that verifies it.
- **BREAK_IT.md** — 20 failure modes with defences and test names, the manual
  atomicity procedure, five unfixed issues, and six deliberate behaviours that
  look like bugs.
- **AI_LOG.md** — what AI got wrong here, in detail.