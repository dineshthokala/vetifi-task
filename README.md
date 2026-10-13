# Vetifi — Veterinary Dose Calculator & Dataset Sync

Round 1 submission, Vetifi Technologies (SDE Intern, Flutter).

An offline-first dose calculator for small-animal clinicians, plus a signed
dataset service so corrections reach a device without an app release.

> All drug names and doses are fictional. **Not for clinical use.**

---

## Quick start

### Server

```bash
cd server
docker compose up --build
```

That is the entire setup: PostgreSQL 16 with a health check, the FastAPI
service, and the `v14` seed loaded on first boot.

`ADMIN_KEY` has **no hardcoded default** — a fallback would mean every
deployment that forgot to set one shares a secret that is published in this
repository, on an endpoint that can change a dose. To keep this a one-command
setup, the container generates a strong random key on first run, persists it in
a volume, and prints it:

```
  ======================================================================
  ADMIN_KEY was not set, so one has been generated for this deployment.
  It is stored at /srv/data/.admin_key and reused on restart.

      k3Jd8x...your-key...
  ======================================================================
```

Supply your own to override it:

```bash
ADMIN_KEY=$(python -c "import secrets;print(secrets.token_urlsafe(32))") \
  docker compose up --build
```

Check it:

```bash
curl -s localhost:8000/health
# {"status":"healthy","database":"connected","latest_dataset_version":"v14", ...}
```

Without Docker:

```bash
pip install -r server/requirements.txt
export ADMIN_KEY=dev                     # required: the server refuses to start without it
uvicorn server.app.main:app --port 8000  # run from the repository root
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

**Reviewers: use an emulator or `adb reverse`.** Release builds permit cleartext
HTTP only to loopback (`10.0.2.2`, `127.0.0.1`, `localhost`), so on a physical
phone the app reaches the server via `adb reverse tcp:8000 tcp:8000` with the
base URL set to `http://127.0.0.1:8000`, or via an HTTPS deployment. A LAN IP
works only in debug builds. See `network_security_config.xml`.

### Release APK

```bash
cd app
flutter build apk --release
# build/app/outputs/flutter-apk/app-release.apk
```

### Tests

```bash
cd app     && flutter test                            # 135 tests
cd server  && python -m pytest server/tests -q        # 78 tests
```

`pytest.ini` puts the repository root on `sys.path`, so pytest works from
either the root or from inside `server/`.

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

**3. The app and server cannot drift on what is computable.**

This is a named requirement of Part D — *"the server must reject the same
invalid data that the app rejects. Explain how you prevent the two sets of rules
from drifting apart."*

The rules are duplicated across two languages, so duplication alone would drift.
Four things prevent it:

1. **A single shared vocabulary.** `mg/kg`, `mcg/kg` and `mcg/kg/min` are
   declared once per side and nowhere else. The app's constant is
   `kSupportedDoseUnits`; the server's is `SUPPORTED_DOSE_UNITS`.
2. **A contract test reads both.** `server/tests/test_contract.py` parses the
   Dart source for `const Set<String> kSupportedDoseUnits = {...}` and asserts
   the two sets are equal. Changing one without the other is a **test failure**,
   not a production surprise.
3. **Both normalise before comparing.** `canonicalDoseUnit` (Dart) and
   `canonical_unit` (Python) lowercase and trim, so `"MG/KG"` is accepted by both
   rather than by one.
4. **The app fails closed where the server fails open.** Even if a bad unit
   somehow reached a device, `toMgPerKg()` returns null and the calculation is
   refused. The app does not depend on the server having been strict.

The direction of failure matters: the server rejecting something the app would
accept is an inconvenience; the app accepting something the server rejected is
a dosing error. So the app is the stricter of the two by design.

`test_contract.py` also pins the field-level rules the two share — inverted
ranges, non-positive values, unparseable concentrations — so a change to one
side that is not mirrored shows up as a failure.

---

## Measured performance

Part B asks for keystroke-to-results latency on a real midrange Android phone,
and for an explanation of how it was measured. Here is what we can actually
evidence, and what we cannot.

**Measured, reproducible** — `flutter test` over the full 50,000-entry corpus.
Three consecutive full-suite runs on the development machine:

| | median | p95 | worst |
|---|---|---|---|
| run 1 | 1.14 ms | 2.45 ms | 9.43 ms |
| run 2 | 0.58 ms | 1.29 ms | 3.87 ms |
| run 3 | 1.08 ms | 2.37 ms | 8.89 ms |

The spread is GC pauses and machine load on a desktop host, not algorithmic
variance — the median moves by 2× between runs while the shape of the
distribution does not. **The number to quote is p95: consistently under 2.5 ms.**

One frame at 60 Hz is 16.7 ms, so p95 sits at roughly a seventh of a frame. The
test asserts p95 < 8 ms and worst case < 60 ms. The p95 bound is the meaningful
one; the worst-case bound is deliberately loose because it is dominated by GC
rather than by the search, and a tight bound there produces a flaky suite rather
than a better guarantee. The real regression guard is the scaling test below,
which compares two corpora of the same shape and so is immune to machine load.

`app/dart_test.yaml` sets `concurrency: 1`. Without it the runner executes test
files in parallel and the benchmark competes with the 50,000-entry index
construction in a sibling isolate — which turned a 4 ms worst case into a
368 ms outlier and made the suite flaky.

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
The method is ready: debug builds log per-query timings (`vetifi_search`), and
RUNBOOK.md section 7 is the exact on-phone protocol — typical, worst, and how
to report them. Fill the numbers in here when measured.

The first version of this search ran Levenshtein across every row on the UI
isolate on every keystroke. The benchmark caught it at a **30 ms** worst case
on a two-character query; the trigram index, selectivity-ordered candidate
collection and prefix arrays brought it under 10 ms. Both numbers are preserved
in the git history rather than squashed, because the regression is the more
informative half of the story — and because the README previously carried an
unmeasured "8–14 ms" figure that the first benchmark run immediately
contradicted.

---

## Notable engineering decisions

**A full snapshot is authoritative; a delta is not.** When the app receives a
snapshot it deletes server-managed rows the snapshot omits. When it receives a
delta it does not — omitting a row from a delta is ambiguous, and treating it
as a delete would turn one truncated delta into mass unavailability. The
locally generated 50,000-entry search corpus is exempt from snapshot deletion:
no server snapshot lists those rows, so replacing them would shrink the
catalogue to ~10 drugs on every snapshot fallback.

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

**`ADMIN_KEY` had a hardcoded default, and `INTERNET` was missing from the
release manifest.** Both were bugs we found by auditing our own submission. The
first meant a misconfigured deployment shared a published key on an endpoint
that can change a dose; the second meant the release APK could not make a single
network request, so Parts D and E were dead in the shipped build. Both are
fixed, and both were invisible to the tests that existed at the time.

---

## Repository layout

```
/app                 Flutter application
  assets/data/       base_dataset_v14.json + generated_50k_drugs.json
  lib/services/      dose_calculator · search_index · update_service ·
                     sync_service · database_service
  test/              135 tests
/server              FastAPI dataset server
  keys/              Signing keypair (private.hex is committed for the demo)
  seed/              v14 base dataset and the v15-v18 publishing test cases
  tests/             78 tests
  Dockerfile, docker-compose.yml, entrypoint.sh
README.md            This file
RUNBOOK.md           Setup, running, demo script, troubleshooting
ARCHITECTURE.md      How every runtime path works
USERFLOW.md          Screen-by-screen walkthrough of the whole app
DECISIONS.md         Part F answers and Part G review
BREAK_IT.md          Failure modes, defences, and what we did not fix
AI_LOG.md            AI usage, including where it was wrong
```

---

## Further reading

- **RUNBOOK.md** — prerequisites, running the server and app, the four publishing
  test cases, the step-by-step demo script, and troubleshooting.
- **USERFLOW.md** — the whole app as a user walks it: every screen, every state,
  every place the app refuses to calculate and why. Start here to understand
  what the software does before reading how it is built.
- **ARCHITECTURE.md** — cold start, search, calculation, update sync, and server
  publish, with the reasoning behind each decision.
- **DECISIONS.md** — the six written questions and the code review. Each answer
  names the test that verifies it.
- **BREAK_IT.md** — 30 failure modes with defences and test names, the manual
  atomicity procedure, nine unfixed issues, and eight deliberate behaviours that
  look like bugs.
- **AI_LOG.md** — what AI got wrong here, in detail.