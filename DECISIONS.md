# DECISIONS.md — Clinical and Architectural Reasoning

Answers to Part F, and the code review required by Part G.

**Everything described here is implemented and tested.** Where a behaviour is
claimed, a test pins it; the test name is given so you can check it.
`app/test/decisions_examples_test.dart` verifies the worked examples in
questions 1 and 3 numerically.

---

## Part F: Written questions

### 1. Small doses

A 2.5 kg cat dosed at 0.05–0.07 mg/kg from a 2.5 mg/mL solution needs
0.05–0.07 mL. The result card shows `0.05 – 0.07 mL` large, the active dose
`0.125 – 0.175 mg` beside it, and the vial concentration beneath. Below 1 mL
the card adds: *"Use a 1 mL tuberculin syringe; a standard 3 mL syringe has
0.1 mL graduations and cannot resolve this."* A 40 kg dog needing 38.4 mL shows
`38.4 mL` with no advisory — a large syringe delivers it accurately.

**Refusal threshold: 0.01 mL**, the smallest syringe resolution in normal use.
Below that the app errors — *"Required volume is below the measurable range of
any syringe. Dilute before administering."* — rather than printing `0.000 mL`,
which reads as an instruction to draw up nothing.

From 0.01 to 0.1 mL it refines the display and warns about syringe choice.
Above 10 mL it drops to one decimal and, when that rounding exceeds 1% of the
volume, states the cost. Where rounded and exact differ, the exact figure
prints underneath.

*Tests: `dose_calculator_test.dart` → "Sub-measurable volumes", "Volume
formatting"; `decisions_examples_test.dart` → "DECISIONS Q1".*

---

### 2. Missing species data

**The strongest argument for showing the dog dose with a warning.** In a rural
emergency with a dying patient, refusing can be the more dangerous choice: an
experienced clinician can extrapolate from body composition or drug-specific
metabolism, and a labelled reference point gives them something to adjust
rather than forcing unaided recall.

**Decision: refuse.**

Cats are not small dogs, and the error is asymmetric — feline glucuronidation
is markedly slower, and canine-formulary drugs often have narrow feline
margins.

The deciding factor is presentation. The fallback number would render
identically to every valid result — same large type, same confirmation. Under
time pressure a number that looks validated gets used, and the warning is the
part that fails: warnings are skimmed and ignored under load. Once the app has
shown one, the threshold for trusting the next drops.

So the app never presents the cat dose as existing: *"Cannot calculate: No dose
data available for cat."* The same reasoning refuses unrecognised units.

*Test: `dose_calculator_test.dart` → "refuses a missing or null species dose".*

---

### 3. Bag volume

**Yes, and the app accounts for it.** Added drug volume gives the patient
`V_drug / (V_bag + V_drug)` of the intended concentration. The CRI card shows
intended concentration, in-bag concentration, and dilution percentage.

**Does not matter.** 1.875 mL into a 500 mL bag: intended 0.150 mg/mL,
delivered 0.1494 — a 0.37% reduction, inside the ±5% typical of an IV pump. The
app says so rather than nagging.

**Matters.** 4.5 mL into a 100 mL bag: 100/104.5 = 95.7% of intended, a 4.3%
underdose. Above 2% the app gives the fix: *"Withdraw 4.50 mL of fluid from the
bag before adding the drug."* The threshold is 2% because that is where dilution
error approaches the pump's own accuracy — below it the correction is noise,
above it the correction is real.

The app also warns if the drug volume exceeds the bag volume, which is nearly
always a wrong concentration or a decimal slip.

*Tests: `dose_calculator_test.dart` → "reports the dilution caused by the added
volume", "warns when the drug meaningfully dilutes the bag"; `decisions_examples_test.dart`
→ "DECISIONS Q3".*

---

### 4. Users who never update

Offline for five months with v14 and the wrong Benzaprol concentration is outside
the app's control. It cannot force an update. What it can do is be honest about
what it holds, and be correct about that data meanwhile.

1. **Never present a stale result as current.** The dataset version appears on
   every result screen, so any dose is traceable to a version.
2. **State the age.** After 60 days a banner reads *"Formulary v14 is 214 days
   old. This dataset may contain concentrations that have since been
   corrected."*, escalating after 180 days. This turns a silent risk into a
   visible one.
3. **Parse defensively at any age.** v14's `"10%"` is read as 100 mg/mL, so a
   stale entry yields a defensible number rather than a crash or a 10× error.
4. **Never let connectivity change an answer.** No network call occurs during a
   calculation, so reconnecting mid-session cannot alter a result.

**Deliberately not built:** BLE/mDNS peer-to-peer sync, so one updated device
refreshes offline siblings. Signed datasets over an ad-hoc radio need their own
threat model. We would rather ship the staleness warning honestly than a
half-built version of it.

*Test: `decisions_examples_test.dart` → "DECISIONS Q4".*

---

### 5. Leaked signing key

**Attacker's capability.** With the private key and any network position —
rogue Wi-Fi, DNS spoofing — an attacker mints lethal payloads and signs them
correctly. Every syncing app accepts them: they are genuinely signed.

**The key lives on the server.** `private.hex` is committed to the repo, copied
into the Docker image, and used to sign at request time — so anyone who reads
the repo or controls the host can forge doses. Verification covers the network
path, not host compromise. This is the issue we would not release with (see
BREAK_IT).

**Effect.** Offline devices keep working on stale data. Devices that sync adopt
the attacker's doses silently: nothing signals a problem.

**Recovery needs an app release.** The public key is compiled into the binary,
so rotation means a new build — reaching users through a channel we do not
control, worst for the offline population most likely affected.

**What we would change:** an offline root key signing short-lived
intermediates; a root-signed revocation list reusing the existing trust path;
k-of-n threshold signing; an append-only transparency log of every published
hash.

---

### 6. Limits of the design

**Where this is the wrong choice: a national formulary of ~500,000 entries on
entry-level Android (≤2 GB RAM) over 2G.**

Why it breaks: the search index holds an id and name per entry, rebuilt at
every cold start and copied to an isolate per query — at 500k that pass is
itself a visible stall. It is in-memory, so re-derived every launch. Updates
arrive as JSON deltas applied row by row — megabytes per client.

**What we would use instead:** SQLite FTS5 with a trigram tokenizer, queried
in-process — deletes the in-memory index, already on disk, built incrementally.
Partitioned datasets by region and species, so a device syncs only what it
needs. Binary changesets via the SQLite session extension. A recently-used
cache, so the 50–200 drugs a clinic reaches for never need a round trip.

Tuned for a formulary a clinic can hold in memory: right up to ~50,000 entries,
wrong well before 500,000.

---

## Part G: Code review

### Function 1 (Dart)

```dart
double volumeMl(double weight, String unit, double dosePerKg,
String concentration) {
final kg = unit == 'lb' ? weight / 2.2 : weight;
final mgPerMl = double.parse(concentration.split(' ')[0]);
final doseMg = kg * dosePerKg;
return double.parse((doseMg / mgPerMl).toStringAsFixed(1));
}
```

Ranked by harm to the animal:

1. **`toStringAsFixed(1)` destroys small volumes.** A kitten needing 0.04 mL
   becomes `0.0 mL` — no treatment, displayed as a confident answer. One needing
   0.06 mL becomes `0.1 mL`, a 67% overdose. Both silent.
2. **Unrecognised concentration is a crash or a wrong number.** `"10%"` makes
   `double.parse` throw `FormatException`. `"0 mg/mL"` parses to 0 and the
   division yields `Infinity`.
3. **The unit test is silently wrong for anything but exactly `"lb"`.** `"lbs"`,
   `"LB"`, or a typo all fall through and are treated as **kilograms**: a 22 lb
   dog entered as `"lbs"` is dosed as 22 kg, a 2.2× overdose with no warning.
   More dangerous than the item below.
4. **`weight / 2.2` instead of `* 0.45359237`** — a systematic 0.21% error. Real,
   but absorbable into clinical judgement.
5. **No domain validation.** Negative, zero, or NaN weight passes through; the
   dose range is unchecked; `dosePerKg` itself is unvalidated.

**Corrected implementation** — `app/lib/services/dose_calculator.dart`, tested in
`app/test/dose_calculator_test.dart`. The two behaviours that matter most, both
absent from the original:

```dart
/// Returns null rather than passing the range through unchanged. A previous
/// version returned `this` for any unrecognised unit, which silently treated
/// g/kg as mg/kg: a 1000x underdose.
DoseRange? toMgPerKg() {
switch (unit) {
case 'mg/kg':
return this;
case 'mcg/kg':
return DoseRange(min: min / 1000, max: max / 1000, unit: 'mg/kg');
default:
return null;
}
}

// Volumes below the smallest measurable syringe are refused outright rather
// than displayed as a rounded zero.
if (volumeMaxMl < kMinMeasurableVolumeMl) {
return (
result: null,
error: 'Required volume is below the measurable range of any syringe. '
'Dilute before administering.',
);
}
```

---

### Function 2 (Dart)

```dart
Future<void> applyUpdate(File file) async {
final db = await openDb();
await db.delete('drugs');
final data = jsonDecode(await file.readAsString());
for (final d in data['upserts']) {
await db.insert('drugs', Drug.fromJson(d).toMap());
}
await prefs.setString('dataset_version', data['dataset_version']);
}
```

Ranked by harm to the animal:

1. **The dataset is destroyed before it is validated.** `db.delete('drugs')` runs
   before the file is read, decoded, or checked. Any later failure — truncated
   download, disk full, process killed, JSON error — leaves the vet with **zero**
   drugs during an emergency. The most serious problem here: it converts any
   transient error into total loss of function.
2. **No cryptographic verification.** Contents are applied unconditionally, so
   anyone who can substitute the file can change every dose.
3. **No transaction, and the version is written outside it.** A crash between
   inserts and `prefs.setString` leaves data and version disagreeing. Worse,
   `prefs` and the database are separate stores with no shared commit, so "v15
   over v14 data" is representable and unrecoverable.
4. **`data['upserts']` throws on a full snapshot**, which carries `drugs` — so a
   legitimate server payload crashes the updater.
5. **Deleted drugs never return, and withdrawals are unrepresented**, so a
   withdrawn drug is resurrected by the next update.

Ours wraps the whole application in one SQLite transaction, verifies signature
and hash *before* parsing, refuses a backwards version, and treats a full
snapshot as authoritative — deleting rows it omits — rather than as upserts.

*Tests: `atomicity_test.dart`; `update_security_test.dart`.*

---

### Function 3 (Python, FastAPI)

```python
@app.post("/admin/datasets")
def publish(body: dict, x_admin_key: str = Header(None)):
if x_admin_key != os.environ.get("ADMIN_KEY"):
raise HTTPException(401)
latest = db.execute("SELECT max(version) FROM datasets").scalar()
new_version = f"v{int(latest[1:]) + 1}"
db.execute(f"INSERT INTO datasets (version, payload) "
f"VALUES ('{new_version}', '{json.dumps(body)}')")
return {"version": new_version}
```

Ranked by harm to the animal:

1. **SQL injection through the payload.** `json.dumps(body)` is interpolated
   straight into SQL: a name containing `'` breaks the statement, and a
   deliberate payload closes it and injects arbitrary doses for every connected
   clinic.
2. **The version comes from a lexicographic `max()`.** Over a text column that
   returns `'v9'`, not `'v14'`, because `'9' > '1'`. Once v9 exists the server
   derives v10 from it, silently forking the version line; a client on v14 would
   never see v15.
3. **Authentication bypasses when `ADMIN_KEY` is unset.** `os.environ.get` then
   returns `None` and the test is `None != None` → `False` → no exception is
   raised and the request is **authenticated**. A misconfigured deployment is a
   wide-open one. The `!=` is also not constant-time.
4. **No concurrency control.** Two publishes read the same `latest`, derive the
   same version, and both insert. No idempotency key, no unique constraint, no
   isolation; published versions are mutable.
5. **No payload validation.** No schema check, no concentration parse, no
   inverted-range or unit check. Anything reaches production.
6. **No `commit()`.** Under `autocommit=False` the insert may never persist,
   leaving the caller holding a version number that does not exist.

Ours uses parameterised queries, derives the version from an integer
`version_num` with a unique index, takes a row lock via `SELECT ... FOR UPDATE`
before deriving it, refuses to start without `ADMIN_KEY`, compares with
`hmac.compare_digest`, honours an `Idempotency-Key`, and validates every field
before publishing.

*Tests: `test_hardening.py`, `test_server.py` (concurrent publish → exactly one
201 and one 409).*