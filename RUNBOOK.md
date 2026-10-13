# RUNBOOK.md — Setup, Running, and Demonstrating

Everything needed to get the system running, verify it, and record the demo.
For how it works see [ARCHITECTURE.md](./ARCHITECTURE.md).

---

## 0. Prerequisites

| | Version used | Notes |
|---|---|---|
| Flutter | 3.35.1 stable | Dart 3.9+ |
| Android SDK | 36 | Required — the app is Android-only, see below |
| Docker | Compose v2 | PostgreSQL 16 runs in a container |
| Python | 3.12+ | Only needed for running the server or tests outside Docker |

### The app is Android-only

`sqflite` has no Windows or web implementation. `flutter run -d chrome` and
`flutter run -d windows` will fail on database initialisation. Use an emulator
or a USB device.

---

## 1. Server

### Docker (recommended)

```bash
cd server
docker compose up --build
```

First build takes a few minutes. On startup it prints a generated admin key:

```
  ======================================================================
  ADMIN_KEY was not set, so one has been generated for this deployment.
  It is stored at /srv/data/.admin_key and reused on restart.

      k3Jd8x...your-key...
  ======================================================================
```

**Copy that key.** It authorises publishing dataset versions and you need it
for every admin call below. It persists across restarts in the `admin_key_data`
volume.

To supply your own:

```bash
ADMIN_KEY=$(python -c "import secrets;print(secrets.token_urlsafe(32))") \
  docker compose up --build
```

### Verify

```bash
curl -s localhost:8000/health
```

```json
{"status":"healthy","database":"connected","latest_dataset_version":"v14",
 "public_key":"2f67f2dc…"}
```

`latest_dataset_version: v14` confirms the seed loaded.

### Without Docker

```bash
pip install -r server/requirements.txt
export ADMIN_KEY=dev
uvicorn server.app.main:app --port 8000
```

Run from the **repository root**, not from `server/` — the imports are
`server.app.*`. `ADMIN_KEY` is mandatory here: the server refuses to start
without it, because a hardcoded fallback would mean every deployment that
forgot to set one shares a published key on an endpoint that can change a dose.

The database defaults to SQLite at `server/vetifi_server.db`. Set
`DATABASE_URL` to point at PostgreSQL instead.

---

## 2. App

### Start an emulator

One is already configured:

```bash
flutter emulators --launch Medium_Phone
```

Wait for the home screen, then from `app/`:

```bash
flutter pub get
flutter run
```

### Pointing at the server

The default base URL is `http://10.0.2.2:8000` — the host machine as seen from
an Android emulator. That works with no configuration.

**On a physical device** the emulator alias is meaningless. Either:

- open **Settings** (gear icon in the app bar) and set the base URL to
  `http://<your-LAN-IP>:8000`, or
- use `adb reverse tcp:8000 tcp:8000` and point the app at `http://127.0.0.1:8000`.

Release builds permit cleartext HTTP only to the loopback family
(`10.0.2.2`, `127.0.0.1`, `localhost`). Debug builds permit it to any host, so
a LAN address works in debug. See
`app/android/app/src/main/res/xml/network_security_config.xml`.

### Build the submission APK

```bash
cd app
flutter build apk --release
# app/build/outputs/flutter-apk/app-release.apk   (~48 MB)
```

Debug-signed, application id `com.example.vetifitask`. Suitable for a
submission link. Before relying on sync in that build, confirm the permission
actually landed:

```bash
grep -o 'permission.INTERNET' \
  app/build/app/intermediates/merged_manifests/release/processReleaseManifest/AndroidManifest.xml
```

Flutter's template declares `INTERNET` only in `src/debug` and `src/profile`,
so a release build without it in the **main** manifest has no network access at
all. This was a real defect in an earlier revision of this submission.

---

## 3. Tests

```bash
cd app     && flutter test          # 128 tests, ~20s
cd server  && python -m pytest -q   # 68 tests,  ~7s
```

`pytest.ini` puts the repository root on `sys.path`, so pytest works from
either the repository root or from inside `server/`.

```bash
flutter analyze          # expect: No issues found!
```

### Targeted runs

```bash
# Search behaviour and the latency benchmark
cd app && flutter test test/search_test.dart

# The four chaos cases and mandatory signature verification
cd app && flutter test test/update_security_test.dart

# Transaction rollback
cd app && flutter test test/atomicity_test.dart

# Dosing, refusals, thresholds
cd app && flutter test test/dose_calculator_test.dart

# App and server agreeing on the bytes
python -m pytest server/tests/test_e2e_update.py -v

# Per-query search breakdown
cd app && dart run tool/bench_search.dart
```

`app/dart_test.yaml` sets `concurrency: 1`. This is required, not incidental:
the runner otherwise executes test files in parallel isolates, and the latency
benchmark competes with the 50,000-entry index construction in a sibling file.

---

## 4. Demo Test

This follows Part H.4. Steps 1–4 are the required content; step 5 is optional.

### Step 1 — Works with no server at all

```bash
# Leave the server stopped. Enable airplane mode on the device.
```

1. Launch the app. It loads 50,010 drugs on first launch with no network.
2. Search `melokin` → **Meloquin** appears. Search `benzaprl` → **Benzaprol**.
3. Open Veloxamine, select Dog, enter `20` → **2.0 – 4.0 mL**, with the total
   dose in mg and the concentration alongside.
4. Open Benzaprol and show the `"10%"` line reading **100 mg/mL**.
5. Open Quilomid (`0 mg/mL`) and show it refuses to calculate.

### Step 2 — Airplane mode, server running

1. Start the server. Enable airplane mode.
2. Tap **Settings → Sync now**.
3. It reports it cannot reach the server and is using local data.
4. The dataset badge still reads `v14`. Nothing changed.

### Step 3 — Online with the server refusing updates

```bash
CHAOS=1 docker compose up -d server
```

1. Disable airplane mode. **Settings → Sync now**.
2. The update is refused. The badge still reads `v14`.
3. For a deterministic demonstration rather than a lucky one:

```bash
curl -s http://localhost:8000/v1/datasets/v14 -H "X-Force-Chaos: tampered"
curl -s http://localhost:8000/v1/datasets/v14 -H "X-Force-Chaos: truncated"
curl -s http://localhost:8000/v1/datasets/v14 -H "X-Force-Chaos: bad_checksum"
curl -s http://localhost:8000/v1/datasets/v14 -H "X-Force-Chaos: server_error"
```

Show that the app rejects each one and the local dataset is untouched.

### Step 4 — Online, a real update lands

```bash
docker compose up -d server      # chaos off

KEY=<the generated ADMIN_KEY>
curl -s -X POST http://localhost:8000/v1/admin/datasets \
  -H "X-Admin-Key: $KEY" -H "Content-Type: application/json" \
  -d @server/seed/update_v15.json
```

```json
{"status":"published","dataset_version":"v15","base_version":"v14","sha256":"…"}
```

1. Tap **Settings → Sync now**.
2. The badge moves **v14 → v15**.
3. Search `Quilomid` — now shows **Withdrawn**, and opening it refuses to
   calculate and explains why.
4. Search `Dopraxine` — new in v15. Select Dog, and the CRI fields appear.

### Step 5 — Close on what you are least confident about

We would say **the search latency claim**: it is measured on a desktop
development machine, not on midrange Android hardware. The numbers in the
README are reproducible and the test guards against a regression, but nobody
has run this on the device class the brief asks about.

---

## 5. The publishing test cases

The brief supplies four files. All four behave as specified:

```bash
KEY=<ADMIN_KEY>
post() { curl -s -o /dev/null -w "%{http_code}\n" -X POST \
  http://localhost:8000/v1/admin/datasets \
  -H "X-Admin-Key: $KEY" -H "Content-Type: application/json" -d "$1"; }

post "$(cat server/seed/update_v15.json)"   # 201  valid, accepted
post "$(cat server/seed/update_v16.json)"   # 400  dataset_version v13 goes backwards
post "$(cat server/seed/update_v17.json)"   # 400  schema_version 3 unsupported
post "$(cat server/seed/update_v18.json)"   # 400  truncated, not valid JSON
```

Note `update_v15` must be published first — the others are relative to a base
that only exists after it.

---

## 6. Troubleshooting

**The app cannot reach the server.**
Check `curl -s localhost:8000/health` from the host. From the emulator, the
host is `10.0.2.2`, not `localhost`. On a physical device use `adb reverse`.

**"Update refused: the manifest failed signature verification."**
The server's signing key does not match the key compiled into the app. The
public key is `server/keys/public.hex` and is hard-coded in
`app/lib/services/update_service.dart`. If you regenerated the keypair, copy the
new public hex into `_compiledInPublicKeyHex` and rebuild. This is the
signature check working as intended.

**The server exits at startup with an ADMIN_KEY error.**
Running outside Docker without the variable set. Either export it or use
Docker, which generates one automatically.

**`flutter run` fails with a licence or SDK error.**
`flutter doctor --android-licenses`, then `flutter doctor`.

**Tests pass alone but fail in the full suite.**
`app/dart_test.yaml` must be present with `concurrency: 1`. Without it the
latency benchmark is measured under CPU contention and produces outliers.

**A test database is left behind in `server/tests/`.**
Expected on Windows: SQLAlchemy holds the file open until the pool is
disposed. It is overwritten on the next run and excluded by `.gitignore`.

**The app is stuck showing `unknown` as the dataset version.**
The database failed to initialise. Uninstall the app to clear its SQLite file
and relaunch.

---

## Further reading

- [ARCHITECTURE.md](./ARCHITECTURE.md) — how every runtime path works
- [DECISIONS.md](./DECISIONS.md) — the six written questions and the code review
- [BREAK_IT.md](./BREAK_IT.md) — failure modes, defences, and what was not fixed,
  including the manual atomicity procedure for a real process kill
- [AI_LOG.md](./AI_LOG.md) — where the AI was wrong, in detail