# AI_LOG.md — AI Usage, Where It Was Wrong, and What Changed

The brief asks which AI tools were used, an honest estimate of how much code was
AI-generated, at least two cases where the AI was wrong or unsafe, and one
decision we changed our mind about.

---

## 1. Tools and scope

| Tool | Used for |
|---|---|
| Claude (Opus, via an agentic coding tool) | Most of the implementation, the test suites, and the code review |
| Language models for ad-hoc questions | Ed25519 usage in Dart, SQLite transaction semantics, PostgreSQL locking |

### Honest estimate

Roughly **60% AI-generated**, weighted by volume:

- **Boilerplate and structure** (~40% of lines): SQLAlchemy models, FastAPI
  endpoint bodies, widget trees, serialization, JSON fixtures. AI output was
  fine and we kept it almost unchanged.
- **Genuinely clinical logic** (~20%): we wrote and rewrote the unit-handling,
  the refusals, the thresholds. These are the parts AI got wrong.
- **Tests** (~25%): AI wrote the first drafts. Several were wrong in ways that
  only showed up when they ran — see cases 3 and 4.
- **Prose documentation** (~15%): AI drafts, then rewritten where they made
  claims we had not verified.

The pattern worth stating plainly: **AI was reliable on structure and unreliable
on anything where a wrong answer is silent.** Every serious defect below is a
case where code compiled, tests passed, and the result was still dangerous.

---

## 2. Cases where the AI was wrong or unsafe

### Case 1 — Dimensional analysis failure in the CRI formula

**Prompt:** *"Write a Dart function to calculate how many mL of Dopraxine
(40 mg/mL) to add to a fluid bag for a dog. Dose is mcg/kg/min, fluid rate
mL/hr, bag size mL."*

**Response:**

```dart
double mlToAdd = (doseRate * weight * bagSize) / (concentration * fluidRate);
```

**Why it was dangerous.** Two unit errors that partially cancel:

1. Minutes and hours treated as identical — the factor of 60 min/hr is missing.
2. Micrograms and milligrams treated as identical — the factor of 1000 mcg/mg
   is missing.

Net error 60/1000 = 0.06, so the answer is **16.7× too small**, and the delivered
dose rate is 16.7× the intended one. There is no crash and no NaN: it returns a
plausible-looking number. For an animal on a vasopressor or an analgesic CRI,
that is a lethal overdose presented as a clean calculation.

**What we did instead.** Derived it from units on paper first, then encoded the
derivation:

```
bag_duration_min = bag_size_ml / fluid_rate_ml_hr × 60 min/hr
total_drug_mcg   = dose_rate_mcg_kg_min × weight_kg × bag_duration_min
total_drug_mg    = total_drug_mcg / 1000 mcg/mg
ml_to_add        = total_drug_mg / concentration_mg_ml
```

The 60 and the 1000 are now named in comments in the source, because they are
exactly the factors a future reader would "simplify" away. Verified against a
worked example: a 10 kg dog at 5 mcg/kg/min, 20 mL/hr, 500 mL bag of 40 mg/mL
gives 1.875 mL over 25 hours — pinned in
`test/decisions_examples_test.dart` and `test/dose_calculator_test.dart`.

### Case 2 — It suggested a cross-species fallback

**Prompt:** *"For d004 Meloquin the cat dose is missing. How should the calculator
handle a user selecting Cat?"*

**Response:** *"To provide a helpful experience, fall back to the dog dose
(0.1–0.2 mg/kg) and display an amber warning: 'Cat dose not found; showing dog
dose for reference. Vets know how to adjust doses.'"*

**Why it was dangerous.** The reasoning is superficially reasonable and the
danger is entirely in the presentation. The fallback number is rendered by the
same code path as every valid result — same large type, same green confirmation
styling. A warning is read in bursts and ignored under load, and once the app
has shown one warning, the clinician's threshold for trusting the next one
drops. It converts a refusal into a plausible number with a small caveat
attached.

**What we did instead.** Refused outright: *"Cannot calculate: No dose data
available for cat."* The strongest argument for the AI's position — that
refusing can be worse for a dying patient — is written up properly in
DECISIONS.md question 2, along with why we rejected it. That argument is about
a vet's judgement under time pressure. It is not an argument about whether the
software should render the number as if it were valid.

### Case 3 — Verification written as an optional check

**Prompt:** *"Add Ed25519 signature verification to the dataset download."*

**Response:**

```dart
if (signature != null) {
  if (!verifySignature(body, signature)) return false;
}
```

**Why it was dangerous.** This is the worst defect we found, and it survived
because every test passed. The generated tests always supplied a signature, so
the null branch was never exercised. But the guard means **a missing signature
is treated as "nothing to verify" rather than "verification failed."** Anyone who
can strip one HTTP header — anyone on the network path, which the brief
explicitly names as in scope — injects arbitrary doses and the app accepts them.

The same shape appeared three times: the manifest signature, the payload
signature, and the SHA-256 check.

**What we did instead.** Made every check mandatory. A missing or malformed
signature returns false. Added `update_security_test.dart` → *"an unsigned
payload is refused even when the hash matches"*, which passes a null signature
against a matching hash and asserts rejection. That test now exists precisely
because the original tests could not catch this.

### Case 4 — Code review that missed the lexicographic version bug

**Prompt:** *"Review this FastAPI publish endpoint for problems. Rank by severity."*

**Response** identified SQL injection, timing attack on `!=`, missing
concurrency control, and missing payload validation. All four are real. It did
not mention:

```python
latest = db.execute("SELECT max(version) FROM datasets").scalar()
```

`version` is TEXT, so `max()` is lexicographic: with `v14` present and `v9`
absent it is fine, but once `v9` exists, `max()` returns `'v9'` because `'9' > '1'`.
The server then derives `v10` from `v9`, silently forking the version line. A
client on `v14` would never see `v15`.

**Why it was dangerous.** This is precisely the class of bug the brief warns
about: obvious on reflection, invisible on inspection, and it corrupts the data
rather than crashing.

**What we did instead.** Added an integer `version_num` column with a unique
index, and derive the next version from that rather than from the string. Our
own re-review of Function 3 in DECISIONS.md ranks it second, above the timing
attack. The lesson we took: a review that finds only the *famous* bugs (SQL
injection) has not been read carefully enough.

---

## 3. A decision we changed our mind about

### In-memory search vs. an indexed search

**Initial approach.** Following the brief's 50,000-entry requirement, we loaded
the whole dataset into a Dart `List<Drug>` on startup and ran Levenshtein across
every entry on every keystroke, on the UI isolate.

**Why we changed it.** Only after building a benchmark rather than trusting the
feel of it. `test/search_test.dart` measures a median of 0.9 ms but a worst case
of **30 ms** on a two-character query — two frames, on every keystroke. The
cause was visible in the profile: the prefix and word-prefix passes scanned
every distinct key in the index, so a query like `"in"` matched a large fraction
of 50,000 entries before the result cap was checked. A separate test comparing a
2,000-entry corpus against the 50,000-entry one showed the small corpus was
*faster per query*, which is the signature of a scaling bug rather than a
constant-factor cost.

The fix was structural, not a tuning knob: sorted key arrays with a binary
search for the lower bound instead of a linear scan; a trigram index ordered by
posting-list length so the most selective trigrams are consulted first; caps
checked *inside* the inner loops, since one common word can add thousands of ids;
and the whole search moved to an isolate. Worst case fell from 30 ms to 4.7 ms.

**The generalisable lesson**, and the reason we think it is worth writing down:
the architecture we had was defensible on paper and measurably wrong in practice.
We only found out because we wrote the benchmark that the brief asked for
anyway. Had we taken the "8–14 ms" figure from intuition and put it in the
README — which is roughly what the first draft did — we would have shipped a
janky search and documented it as fast.

The regression is preserved in git history rather than quietly squashed, because
a 30 ms → 4.7 ms change is more informative than the 4.7 ms.

---

## 4. What we did not do with AI

- **No AI-generated code was accepted without being read.** Every clinical
  threshold, every refusal message, and every unit conversion in
  `dose_calculator.dart` was written or rewritten by hand.
- **No AI-written claim in the documentation was left unverified.** The first
  draft of DECISIONS.md described a dilution warning, a staleness banner, and a
  syringe-precision advisory that did not exist in the code. We implemented
  them rather than deleting the claims, and `test/decisions_examples_test.dart`
  now pins the numbers so the prose and the behaviour cannot diverge again.
- **No test was written to match the implementation after the fact** without
  asking what the implementation should do. Case 3 is what that looks like when
  we got it wrong.