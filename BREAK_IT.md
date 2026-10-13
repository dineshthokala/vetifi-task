# BREAK_IT.md — Failure Modes, Defences, and What We Did Not Fix

Every row below names a way the app could still show a wrong or misleading
number, what we do about it, and the test that proves it. Test names are exact
and greppable; `test_immutability.py` lives in `server/tests/`.

Two columns deserve attention:

- **Unfixed** — a real residual risk, not yet mitigated.
- **Deliberate** — a behaviour we chose, which someone might reasonably call a
  bug. We state it rather than leave it to be discovered.

---

## 1. Failure modes and defences

| # | Failure mode | Harm | Defence | Test |
|---|---|---|---|---|
| 1 | **Zero concentration** (`d009` Quilomid, `"0 mg/mL"`) | `Infinity mL`, or a divide-by-zero crash mid-resuscitation | `parseConcentration` rejects any value ≤ 0; calculation is refused | `dose_calculator_test.dart` → "refuses a zero concentration" |
| 2 | **Inverted dose range** (`d006` Corvadil, min 8 > max 4) | A vet reads the lower bound as a dose and underdoses by 2× | `min <= max` validated; refused with "Minimum dose (8) exceeds maximum dose (4)" | `dose_calculator_test.dart` → "refuses an inverted dose range and says why" |
| 3 | **Percentage concentration** (`d007` Benzaprol, `"10%"`) | Read as 10 mg/mL instead of 100 mg/mL → **10× overdose** | `"10%"` parsed as 10 g/100 mL = 100 mg/mL; the card also prints the mg/mL equivalent | `dose_calculator_test.dart` → "parses percentage as w/v", "Benzaprol 10% is read as 100 mg/mL" |
| 4 | **Missing species dose** (`d004` Meloquin, no `cat` key) | Canine dose applied to a cat | Refused. No fallback number is ever rendered | `dose_calculator_test.dart` → "refuses a missing or null species dose rather than extrapolating" |
| 5 | **Explicit null species dose** (`d003` Pirovane, `"cat": null`) | Same as #4 via a different code path | Parsed as absent, refused identically | same test as #4 |
| 6 | **mcg/kg read as mg/kg** (`d002` Tranzorel) | **1000× overdose** | `DoseRange.toMgPerKg()` converts ÷1000 before any division | `dose_calculator_test.dart` → "converts mcg/kg to mg/kg before dividing by concentration" |
| 7 | **Unrecognised dose unit** (e.g. `g/kg`, or `mcg/kg/min` in a bolus block) | g/kg read as mg/kg is a **1000× underdose**; mcg/kg/min read as mg/kg is a **1000× overdose** | `toMgPerKg()` returns null for any unit it cannot convert, and the calculation is refused. The server rejects the same units at publish time | `dose_calculator_test.dart` → "refuses an unrecognised dose unit", "refuses mcg/kg/min appearing in a bolus doses block"; `test_contract.py` → `test_rejects_uncomputable_units` |
| 8 | **No maximum dose cap** (`d008` Zentrafen, 400 mg) | A 40 kg dog computed at 600 mg | Clamped to 400 mg; the card shows both the uncapped and capped figures | `dose_calculator_test.dart` → "caps the upper bound and reports the uncapped value" |
| 9 | **Comma decimal separator** (`4,5`) | Parsed as 4 → **11% underdose** | Comma normalised to a decimal point before parsing | `dose_calculator_test.dart` → "accepts a decimal point and a decimal comma" |
| 10 | **Pound conversion** | `2.2` introduces a 0.21% systematic error | Exact factor `0.45359237` | `dose_calculator_test.dart` → "uses the exact pound conversion" |
| 11 | **Sub-measurable volume** | A volume of 0.00001 mL displayed as `0.000 mL` reads as "draw up nothing" | **Refused outright** below 0.01 mL, with instructions to dilute. Never rendered as a rounded zero | `dose_calculator_test.dart` → "refuses a volume no syringe can measure", "never renders a non-zero volume as zero" |
| 12 | **CRI dose rate outside the validated range** | A 500 mcg/kg/min rate against a 5–10 range computes 187.5 mL and was displayed as a clean result | Computed, but flagged: *"ABOVE the validated range... This is a 50.0x overdose against the approved maximum."* | `dose_calculator_test.dart` → "flags a dose rate above the validated range" |
| 13 | **Bag dilution from added drug volume** | The patient receives less than the intended concentration | Both concentrations and the dilution percentage are shown; above 2% the app gives the corrective withdrawal volume | `dose_calculator_test.dart` → "reports the dilution caused by the added volume", "warns when the drug meaningfully dilutes the bag" |
| 14 | **Withdrawn drug becoming calculable again** | A recalled or defective drug is dispensed | Withdrawal state round-trips through JSON and SQLite; a full snapshot is treated as authoritative and rows it omits are deleted | `update_security_test.dart` → "a snapshot carrying is_withdrawn is honoured"; `atomicity_test.dart` → "withdrawal and reinstatement are applied in the right order" |
| 15 | **Unsigned or tampered update** | Anyone on the network path changes every dose | Signature and hash verification are **mandatory**: a missing signature is a rejection, not a skip | `update_security_test.dart` → "a missing signature is rejected", "an unsigned payload is refused even when the hash matches" |
| 16 | **Validly signed but wrong payload** | A replayed old dataset rolls back a corrected concentration | Version must be newer, and the payload's own version must match the manifest | `update_security_test.dart` → "a payload declaring a different version than the manifest"; `database_service.applyUpdate` `notNewer` |
| 17 | **Crash during an update** | Half a dataset; drugs silently disappear | One SQLite transaction; atomicity tested against a real engine | `atomicity_test.dart` → "an exception mid-transaction rolls back every row and the version", "data written but not committed is not visible after reopening" |
| 18 | **Search returns the wrong drug** | A vet dispenses one drug believing it is another | Exact > word-prefix > prefix > substring > approximate, with ties broken deterministically. Ambiguous names (`d004`/`d005` both "Meloquin") show route and concentration | `search_test.dart` → "exact match ranks first", "results are deterministic", "the duplicate-name drugs remain distinguishable" |
| 19 | **Stale dataset used without warning** | A vet doses from a formulary with a known-bad concentration | Dataset age is recorded and surfaced after 60 days | `home_screen.dart` `_stalenessMessage` |
| 20 | **Calculation depends on connectivity** | The same input gives different answers on different days | `DoseCalculator` is a pure function; a test asserts it imports nothing that can reach the network | `update_security_test.dart` → "DoseCalculator imports nothing that can reach the network" |
| 21 | **A published version silently edited** | A corrected dose is changed after clinicians have acted on it | No PUT/PATCH/DELETE route exists; a new version can only be an INSERT. A publish from a stale base is a 409, not a silent fork | `test_immutability.py` → "no endpoint can modify a published version", "a stale base is rejected rather than forking" |
| 22 | **Re-uploaded log overwrites the original** | The audit trail stops being trustworthy | `calc_id` is the primary key and duplicates are counted, never replaced | `test_immutability.py` → "calculation logs are append-only too" |
| 23 | **NaN / Infinity / boolean dose numbers published** | Python parses the tokens; Dart rejects them, so no client could ever apply the version — and versions are immutable | The validator requires finite non-boolean numbers; the publish endpoint rejects the raw tokens during parsing; the client flags non-finite ranges | `test_contract.py` → "rejects_nan_and_infinity", "rejects_bool_max_total_mg"; `test_hardening.py` → "rejects_nan_token_at_the_door" |
| 24 | **Two species keys normalising to one** (`"Dog"` and `"dog"`) | The last one silently wins on the client | Refused at publish time; flagged as a validation error on datasets that predate the check | `test_contract.py` → "rejects_duplicate_species_after_normalisation"; `dose_calculator_test.dart` → "flags duplicate species keys after normalisation" |
| 25 | **Drug with no usable dose published** (`doses: {}` or all null) | Publishes as permanently uncalculable | Refused at publish time; surfaced as a global data error on the client | `test_contract.py` → "rejects_empty_and_all_null_doses"; `dose_calculator_test.dart` → "flags a drug with no usable dose data" |
| 26 | **Impossible or client-unreadable concentration** (`"1000%"`, non-ASCII digits) | A 100× scaling error, or a string the server accepts but no client can parse | Percentages above 100 refused; digit classes ASCII-only on both sides so the two accept exactly the same strings | `test_contract.py` → "rejects_impossible_percentage", "rejects_non_ascii_digits_in_concentration"; `dose_calculator_test.dart` → "rejects percentages above 100", "rejects non-ASCII digits" |
| 27 | **Withdrawal published with no reason** | The clinician cannot tell a recall from a deprecation at the refusal moment | `reason` is required (400 if missing or blank); nothing is fabricated server-side | `test_hardening.py` → "withdraw_missing_reason_rejected", "withdraw_empty_reason_rejected" |
| 28 | **One bad log row blocks the whole upload queue** | A single rejected row is resent forever; nothing behind it uploads | The server names refused ids (`rejected_ids`); the client retires them instead of resending | `test_hardening.py` → "reports_rejected_ids", "duplicate_id_within_one_batch_is_not_500" |
| 29 | **Full snapshot deletes the 50,000 generated search entries** | The catalogue silently shrinks to ~10 drugs after any snapshot fallback | Snapshot replace exempts `gen_*` rows: the snapshot is authoritative for server-managed rows only | `atomicity_test.dart` → "generated rows survive a snapshot that omits them" |
| 30 | **Mistyped field in an update crashes parsing** | A `TypeError` escapes and is misreported as "working offline" | `Drug.fromJson` never throws on JSON-shaped input; the parse loop returns `malformed` instead | `dose_calculator_test.dart` → "never throws on mistyped scalars", "treats a boolean max_total_mg as a data error" |

---

## 2. Manual procedure: atomicity under process kill

Part E.2 asks for a demonstration. The automated tests in
`atomicity_test.dart` cover the mechanism; this is the device-level procedure
for the case they cannot reach (an actual process kill).

**Setup:** server running; app installed; app on `v14`; CHAOS off.

1. Launch the app. Note the dataset version badge (`v14`).
2. Publish `v15` to the server:
   ```bash
   curl -s -X POST http://localhost:8000/v1/admin/datasets \
     -H "X-Admin-Key: $ADMIN_KEY" -H 'Content-Type: application/json' \
     -d @server/seed/update_v15.json
   ```
3. Open **Settings** and confirm the version still reads `v14` before the next
   step. (Sync only runs at launch or on demand; this confirms it.)
4. Force-stop the app. Relaunch it. **The kill window is now closed** — the
   transaction has either committed or rolled back.
5. Verify: the version badge reads either `v14` *or* `v15`, and:
   - If `v14`: search for `Quilomid` — it must be present and un-withdrawn,
     because v15 has not landed.
   - If `v15`: search for `Quilomid` — it must show **Withdrawn**, and opening
     it must refuse to calculate with the reason.
6. Repeat with the kill landing mid-sync by using CHAOS to widen the window:
   ```bash
   docker compose up -d
   CHAOS=1 docker compose up -d server
   ```
   With `server_error` selected, the sync fails before any write. The version
   must still read `v14` and the dataset must be unchanged.

**Why this is sufficient.** The whole application — every row and the version
bump — happens inside a single `db.transaction`. SQLite guarantees that a
transaction is either fully committed or fully absent; there is no code path
that writes the version outside the transaction. The automated test
"data written but not committed is not visible after reopening" exercises the
same property at the storage layer, and "an exception mid-transaction rolls back
every row and the version" exercises it under a thrown error.

---

## 3. Issues we did NOT fix

### 3.1 Cross-species extrapolation is refused, but species recognition is permissive

We refuse to substitute a dog dose for a cat. We do **not** validate that a
species key in an incoming dataset is a species we recognise — `horse`,
`rabbit`, and `llama` all become available species and are calculable. This is
deliberate (a rural clinic may treat an exotic species and the dataset is the
authority on what exists) but it means a **misspelled species key is
calculable**. A typo that produced a species nobody searches for is low risk; a
typo that silently merged two species' dose tables would not be.

*Mitigation today:* the species key is shown verbatim on the result card, so an
odd species is visible. *What we would do:* reject unknown species at publish
time against a maintained vocabulary, or at minimum surface unknown keys as an
advisory rather than a normal chip.

### 3.2 Withdrawal is a soft flag, not a hard block

A withdrawn drug is refused by `speciesError`, so it cannot be calculated. But
it remains in the local dataset and still appears in search results, marked. If
a future code path calculated from a `Drug` without consulting `speciesError`, a
withdrawn drug would be dispensable. The protection is one function call away
from every calculation, which is a single point of failure rather than a
structural guarantee.

*What we would do:* filter withdrawn drugs out of the row that
`getDrugsByIds` returns, so the calculator cannot physically be handed one.

### 3.3 Allometric (surface-area) scaling is not implemented

We dose linearly: `mg = weight × mg/kg`. Clearance scales closer to
`kg^0.75`, so a 0.8 kg kitten and a 30 kg dog at the same mg/kg do not receive
equivalent exposure.

*Why not:* manufacturer labelling is expressed in mg/kg, and departing from it
without a pharmacologist's sign-off is a worse failure than the imprecision.
*What we do instead:* weights outside 1–60 kg raise an advisory (tested), and
the 0.01–1500 kg bounds are hard refusals.

**Would we release with this unfixed? Yes**, with the advisory, because linear
mg/kg is the documented standard of care (Plumb's, BSAVA Formulary) and the
alternatives are not clinically validated. But it is the assumption most likely
to be wrong for extreme patients, and it should not be mistaken for a settled
question.

### 3.4 The app cannot recover from a leaked signing key without a release

A single Ed25519 public key is compiled into the binary. Compromise means an
app release, and the users least able to install one are the ones offline.
Fully analysed in DECISIONS.md question 5, including the revocation list we
would build first.

Worse than the recovery problem is the residency problem: the private key is
committed at `server/keys/private.hex`, copied into the Docker image, and used
to sign at request time. Anyone who reads the repo or controls the server host
can mint correctly-signed lethal doses that every installed app accepts.
Signature verification covers the network path; it does nothing against host
compromise.

**Would we release with this unfixed? Not for production.** For this
assignment, yes, because the submission demonstrates the mechanism correctly
and the gap is documented rather than hidden.

### 3.5 Weight plausibility is not species-specific

One advisory band (1–60 kg) covers both species with a 1500 kg hard limit, so
a "40 kg cat" or "500 kg dog" is accepted with at most an advisory. Impossible
values per species should be hard refusals, but the bands need species-specific
clinical sign-off we do not have, and inventing them in an evening risks
refusing a real patient.

*What we would do:* per-species hard limits reviewed against formulary data,
with the advisory bands kept where they are.

### 3.6 Dose and concentration plausibility has no ceiling

Percentages above 100% are refused and digit classes match across sides, but
there is no upper bound on mg/mL concentrations or mg/kg doses — `1e308 mg/kg`
publishes. A ceiling needs a pharmacological basis per drug class, not a
constant.

### 3.7 Idempotency-key lookup races the row lock

The idempotency check runs before the publish lock, so a concurrent retry with
the same key can take a 409 instead of the original result, and the replay
shape differs from the original (200 `already_published` versus 201). Same key
with a different body silently returns the old result. Fixing it means hashing
the body into the key and holding the lock across the check — correct, but a
larger change than tonight allows, and the failure mode is a retryable error,
not a wrong dose.

### 3.8 `X-Force-Chaos` works without `CHAOS=1`

Any caller can force a tampered or error response for their own request. The
blast radius is one response to the caller, and the demo depends on the header,
so this stays as a documented property rather than a fixed one.

### 3.9 There is no rate limiting or authentication on `/v1/calc_logs`

Deliberate: the app may be in the field with no credentials, and the data is
not clinically authoritative. Records are treated as untrusted — every field is
range-checked, NaN and infinity are rejected, batches are capped at 1000, and
deduplication is on `calc_id`. But an unauthenticated endpoint that writes to
the database can still be used to fill disk. A deployment would need a reverse
proxy with a request cap.

---

## 4. Deliberate behaviours that look like bugs

| Behaviour | Why |
|---|---|
| `"10%"` is read as 100 mg/mL | 10% w/v is 10 g/100 mL. Any other reading is a 10× overdose. |
| An out-of-range CRI dose rate is computed *and* flagged, not refused | A vet may have a legitimate reason. Refusing would remove the information they need to override. The flag is unmissable. |
| Two drugs share the name "Meloquin" (`d004`, `d005`) | This is the dataset's problem, not ours. We surface route and concentration on every row rather than silently deduplicating, because picking one of two real formulations on the clinician's behalf is not our call. |
| `"1,200"` parses as 1.2, not 1200 | The brief specifies comma-as-decimal. A user meaning twelve hundred types `1200` or `1200,0`. |
| A delta that omits a drug does not delete it | Only a *full snapshot* is treated as authoritative. Omitting a row from a delta is ambiguous, and treating it as a delete would turn one truncated delta into mass unavailability. |
| Upserting a withdrawn drug reinstates it, with no separate "reinstate" operation | Withdrawal is a flag on the row, not a tombstone: the newest write wins. An explicit reinstatement would be clearer, but the current rule is total (last write in version order decides) and tested. |
| `docker compose` publishes Postgres on 5432 with a default password | Local-demo convenience. A deployment binds it to localhost or removes the mapping; the password is overridable via `POSTGRES_PASSWORD`. |
| Release builds permit cleartext HTTP only to loopback | Signing protects integrity, not confidentiality. See `network_security_config.xml`. |

---

## 5. Known gaps in this submission

- **No video.** The brief asks for up to 5 minutes demonstrating airplane mode,
  then a chaos-mode refusal. Not produced; the scripted equivalent is the manual
  procedure in section 2.
- **Search latency not measured on a physical device.** The brief asks for
  typical and worst keystroke-to-results time on a real midrange phone plus the
  method. Current numbers come from a Dart benchmark on a development machine.
  Measuring on-device is a user-side task; the method is in the README.
- **Tests run against SQLite, not PostgreSQL.** Both are real databases and the
  SQL is portable, but the concurrency test is more meaningful under
  PostgreSQL's row-level locking than under SQLite's file lock.
- **The private signing key is committed** at `server/keys/private.hex`. It is
  regenerated by `server/keys/generate_keys.py` and is required for the demo to
  work out of the box. It must not ship to production — and note that it is the
  exact scenario of DECISIONS.md question 5, which is presumably instructive.
- **`ADMIN_KEY` has no hardcoded default.** If it is not supplied, the
  container generates one, persists it in a volume, and prints it. A deployment
  cannot silently run on a published key, and `docker compose up` is still a
  single command. Running the server outside Docker requires the variable to be
  set; it refuses to start otherwise.