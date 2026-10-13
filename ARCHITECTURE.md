# ARCHITECTURE.md — How the System Works

A walkthrough of every runtime path in the app and the server, in the order they
happen. For setup instructions see [RUNBOOK.md](./RUNBOOK.md).

The organising principle is a single asymmetry: **the app fails closed.** Every
path where data is incomplete, inconsistent, unsigned, or out of date ends in a
refusal or a visible warning — never in a plausible-looking number.

---

## 1. Shape of the system

```
┌─────────────────────────────────────────────────────────────┐
│  Flutter app (offline-first)                                 │
│                                                             │
│  screens/      home · calculator · settings                  │
│  services/     dose_calculator   ← pure, no I/O             │
│                search_index      ← runs in an isolate        │
│                update_service    ← verify, then apply        │
│                sync_service      ← connectivity gate        │
│                database_service  ← SQLite, one txn per write │
│  models/       drug.dart         ← parse + validate          │
│                                                             │
│  local:  assets/data/*.json → SQLite on first launch         │
│  remote: /v1/manifest, /v1/datasets/{v}, /v1/calc_logs       │
└──────────────────────────┬──────────────────────────────────┘
                           │ Ed25519 signed, SHA-256 hashed
┌──────────────────────────▼──────────────────────────────────┐
│  FastAPI server                                              │
│  main.py      routing, concurrency, delta combination        │
│  validator.py field-level rules (vocabulary shared w/ app)   │
│  crypto.py    Ed25519 signing                                │
│  chaos.py     the four required failure modes                │
│  database.py  SQLAlchemy → PostgreSQL or SQLite              │
└─────────────────────────────────────────────────────────────┘
```

Three properties the design leans on, each of which would be expensive to
retrofit:

1. **A calculation cannot reach the network.** `DoseCalculator` imports no
   I/O, no database, no HTTP. Asserted structurally by a test, so a future edit
   cannot quietly break it.
2. **Verification happens before parsing.** Nothing is read as data until its
   signature has been checked.
3. **Writes are single transactions.** A dataset update and its version bump
   commit together or not at all.

---

## 2. Cold start, fully offline

```
app launch
  ├─ WidgetsFlutterBinding.ensureInitialized()
  ├─ LanguageController.init()              → English
  │     (currently commented out in main.dart: language not persisted)
  └─ HomeScreen.initState()
       ├─ DatabaseService.database          → SQLite open, v1→v2 migrate if needed
       ├─ ensureBaseDataset()               → only if drugs table is EMPTY
       │    └─ ONE transaction
       │         ├─ assets/data/base_dataset_v14.json      (10 clinical drugs)
       │         ├─ assets/data/generated_50k_drugs.json   (50,000 search corpus)
       │         └─ write dataset_version + fetched_at
       │    (~320 ms for 50,010 rows, batched at 500)
       ├─ getSearchIndexEntries()           → 50,010 (id, folded name) pairs
       │    content-team entries first, so a real drug wins a tie
       ├─ SearchIndex.fromEntries()         → exact map · prefix arrays ·
       │                                      word map · trigram map · length buckets
       └─ _backgroundSync()
            └─ SyncService.syncNow()
                 └─ connectivity check
                      └─ offline ──▶ return, show "working offline", stop
```

If the process is killed during the initial load, the transaction rolls back,
the drugs table stays empty, and the next launch retries cleanly. There is no
partially seeded state to detect.

### Why the index is in memory

At 50k entries the index costs a few MB and is built in one pass at startup.
Beyond roughly 50k it stops being the right answer — the cold-start pass becomes
visible, and it is re-derived on every launch rather than persisted. SQLite FTS5
would remove it entirely. That trade-off is argued in
[DECISIONS.md](./DECISIONS.md) question 6.

---

## 3. Search

Typing is the only hot path in the app, so it is the only one with a measured
budget: **p95 under 2.5 ms**, roughly a seventh of one 60 Hz frame.

```
keystroke
  ├─ debounce 120 ms                 ← collapses a typing burst into one query
  ├─ ticket = ++_searchTicket
  ├─ compute(searchDrugs, ...)       ← ISOLATE; the UI thread never waits
  │    └─ SearchIndex.search()
  │         1. exact map             → 1000   (returns immediately)
  │         2. word-exact map        →  900
  │         3. prefix                →  800   (binary search, not a scan)
  │         4. word-prefix           →  750   (binary search)
  │         5. trigram candidates, RAREST TRIGRAM FIRST  ← the critical detail
  │              ├─ substring        →  600
  │              └─ bounded Levenshtein → 100–500
  │    sort: score ↓, then name length ↑, then alphabetical
  │         (deterministic: identical queries never reshuffle)
  ├─ getDrugsByIds()                 → hydrate only the ≤60 winners
  └─ if ticket != _searchTicket → DISCARD
```

### Three details that matter more than they look

**Trigrams are consulted rarest-first.** Iterating them in query order means the
first one tried is usually a common prefix (`" m"`) whose posting list runs to
thousands of rows. The result cap then truncates *before any distinctive trigram
is ever consulted*, so genuinely close matches are never seen. Sorting the
query's trigrams by posting-list length fixed a real bug — `melokin` returned
`meloxinil` and not `meloquin`.

**Result caps are checked inside the inner loops.** One common word can map to
thousands of ids. Collecting a whole word's id list before noticing the cap was
why the query `"in"` took 9.4 ms.

**The ticket counter is what makes Part B.3 true.** Search runs in an isolate,
so results can genuinely arrive out of order. A slow query for `"mel"` that
finishes after a fast query for `"meloquin"` is discarded rather than replacing
better results.

---

## 4. Calculation — the path that must never touch a network

```
tap Calculate
  ├─ speciesError(species)
  │     withdrawn? · bad concentration? · missing dose? · inverted range?
  ├─ DoseRange.toMgPerKg()
  │     mg/kg → itself · mcg/kg → ÷1000 · anything else → NULL = REFUSE
  ├─ doseMg = weightKg × mgPerKg
  ├─ apply max_total_mg cap, retaining the uncapped figure for display
  ├─ volumeMl = doseMg ÷ concentrationMgPerMl
  ├─ volumeMax < 0.01 mL?   → REFUSE ("dilute first"), never render 0.000
  ├─ build advisories: syringe choice, rounding cost
  ├─ save CalculationLog locally (uploaded = 0)
  └─ render: volume · total dose mg · concentration · species · weight ·
             route · dataset version · advisories
```

### Refusal thresholds

| Constant | Value | Meaning |
|---|---|---|
| `kMinMeasurableVolumeMl` | 0.01 mL | Below the finest syringe graduation. **Refuse.** |
| `kSmallVolumeThresholdMl` | 0.1 mL | Syringe choice becomes clinically relevant. Advise. |
| `kDilutionWarningFraction` | 0.02 | CRI drug volume as a share of the finished bag. |
| `kAdvisoryMinWeightKg` / `Max` | 1.0 / 60 kg | Unusual but plausible. Advise, do not refuse. |
| `kAbsoluteMinWeightKg` / `Max` | 0.01 / 1500 kg | Outside physiological possibility. **Refuse.** |

### Percentage concentrations

`"10%"` is read as **100 mg/mL** — 10 g per 100 mL w/v. Any other reading is a
10× overdose. The result card additionally prints the mg/mL equivalent so the
derivation is visible rather than implicit.

### CRI

```
bag_duration_min = bag_size_ml ÷ fluid_rate_ml_hr × 60
total_drug_mcg   = dose_rate × weight_kg × bag_duration_min
ml_to_add        = total_drug_mcg ÷ 1000 ÷ concentration_mg_ml
```

The `60` and the `1000` are named in comments because they are exactly the
factors a future reader would "simplify" away. Getting the first wrong is a
16.7× underdose; the second, a 1000× overdose.

A rate outside the validated range is **computed and flagged**, not refused — a
vet may have a legitimate reason, and refusing removes the information they need
to override. The flag states the multiple of the approved maximum.

The result also reports the dilution the added volume causes: intended
concentration, in-bag concentration, and the percentage. Above 2% it gives the
corrective action ("withdraw X mL of fluid first").

---

## 5. Update sync

```
SyncService.syncNow()
  ├─ checkForUpdate()
  │    ├─ GET /v1/manifest?schema=2&current=v14
  │    ├─ signature present?      NO → REJECT      ← mandatory, not optional
  │    ├─ manifest commits to a payload hash? NO → REJECT
  │    ├─ latest ≤ current?            → up to date
  │    └─ delta_available false / client_version_known false → fetch a snapshot
  │
  ├─ downloadAndApply()
  │    ├─ GET /v1/datasets/v15?from=v14      (or the bare URL for a snapshot)
  │    ├─ 404 → retry once as a full snapshot
  │    ├─ sha256(body) == manifest hash?    NO → REJECT
  │    ├─ X-SHA256 header agrees?           NO → REJECT
  │    ├─ signature present and valid?      NO → REJECT
  │    ├─ JSON parses?                      NO → REJECT   (truncated body)
  │    ├─ schema_version == 2?              NO → REJECT
  │    ├─ payload version == manifest?      NO → REJECT
  │    └─ DatabaseService.applyUpdate()
  │         ├─ new ≤ current?      → notNewer    (anti-rollback)
  │         ├─ base ≠ current?     → baseMismatch (delta doesn't apply)
  │         └─ ONE transaction
  │              ├─ snapshot → DELETE rows it does not list
  │              ├─ withdrawals → set is_withdrawn + reason
  │              ├─ upserts → INSERT OR REPLACE (clears the flag on reinstatement)
  │              └─ write dataset_version + fetched_at
  │
  └─ uploadCalcLogs()
       └─ batches of 200, up to 10 pages
          └─ mark uploaded ONLY the records the server confirmed it stored
```

### The trust chain

```
manifest  ──Ed25519──▶  {latest_version, sha256, payload_signature}
                          │
                          ├─ sha256 pins the exact payload bytes
                          └─ payload signature pins the payload itself
```

The manifest is verified **first**, and it is what commits to the payload hash.
So an attacker cannot supply their own hash for their own payload: the hash
arrives inside something already signed.

### Three properties that were missing and are now enforced

**Signature verification is mandatory.** It was previously
`if (signature != null) { … }`, which meant stripping one HTTP header bypassed
verification entirely. A missing signature is now a rejection.

**A full snapshot is authoritative; a delta is not.** A snapshot deletes rows
it does not list, so a withdrawn or removed drug cannot survive as a stale row.
A delta does not — omitting a row from a delta is ambiguous, and treating it as
a delete would turn one truncated delta into mass unavailability.

**Versions only move forward.** A validly signed but older payload is refused,
because an older dataset may carry a concentration that has since been found
wrong.

### Calc log upload

Records are written locally with `uploaded = 0` and flushed in batches when a
connection exists. Only IDs the server confirmed are marked uploaded, so an
interrupted upload re-sends rather than silently dropping records. The server
deduplicates on `calc_id`, so a re-send is harmless.

---

## 6. Server publish

```
POST /v1/admin/datasets
  ├─ hmac.compare_digest(X-Admin-Key, ADMIN_KEY)   ← read per request, rotatable
  ├─ idempotency key seen?  → return the ORIGINAL result (200, not a new version)
  ├─ SELECT … FOR UPDATE (latest)                   ← prevents forks
  ├─ base_version ≠ latest?              → 409
  ├─ version ≤ latest?                   → 400 backwards / 409 exists
  ├─ duplicate ids within one payload?   → 422
  ├─ validate every field                → 422 listing drug_id and field
  ├─ withdraw ∩ upsert ≠ ∅?              → 422
  ├─ withdraw an id that doesn't exist?  → 422
  └─ INSERT — a new row only; no route can ever modify an existing one
```

`/v1/admin/withdraw` creates a new version rather than editing the old one, and
carries the same idempotency and conflict handling.

### Immutability

Asserted against the **live routing table**, not by reading the source:
`test_immutability.py::test_no_endpoint_can_modify_a_published_version` fails if
anyone adds a `PUT`, `PATCH` or `DELETE`. Without that check the property would
hold only by absence, and absence is not a guarantee.

---

## 7. CHAOS mode

With `CHAOS=1` the middleware randomly returns one of four failures on
`/v1/manifest` and `/v1/datasets`:

| Mode | What it does | How the app rejects it |
|---|---|---|
| `tampered` | Alters the body | Signature fails |
| `bad_checksum` | Valid body, wrong `X-SHA256` | Hash mismatch |
| `truncated` | Cuts the body in half | Hash mismatch, then parse failure |
| `server_error` | HTTP 500 | Non-200, no write |

`X-Force-Chaos: <mode>` triggers a specific one deterministically, which is
what makes the behaviour demonstrable on camera rather than left to chance.

---

## 8. Where the tests sit

| Concern | Test |
|---|---|
| Dosing, refusals, thresholds, CRI | `app/test/dose_calculator_test.dart` |
| The four chaos modes, signature mandatory | `app/test/update_security_test.dart` |
| Transaction rollback, crash-and-reopen | `app/test/atomicity_test.dart` |
| Search ranking, typos, latency | `app/test/search_test.dart` |
| The numbers quoted in DECISIONS.md | `app/test/decisions_examples_test.dart` |
| Unit vocabulary matches the server | `server/tests/test_contract.py` |
| Endpoints, deltas, concurrency | `server/tests/test_server.py` |
| Ambiguous publishes, malformed logs | `server/tests/test_hardening.py` |
| Version immutability | `server/tests/test_immutability.py` |
| App and server agree on the bytes | `server/tests/test_e2e_update.py` |

`test_e2e_update.py` re-runs the app's decision tree against the real server's
real responses, with the Ed25519 check reimplemented in Python so a bug in the
Dart verifier cannot make it pass.

---

## Further reading

- [RUNBOOK.md](./RUNBOOK.md) — setup, running, and the demo script
- [DECISIONS.md](./DECISIONS.md) — the six written questions and the code review
- [BREAK_IT.md](./BREAK_IT.md) — failure modes, defences, and what was not fixed
- [AI_LOG.md](./AI_LOG.md) — where the AI was wrong, in detail