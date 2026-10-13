# USERFLOW.md — How a User Moves Through Vetifi

Every screen, every state, and every path where the app stops and says no.

This is the user-facing walkthrough. For why the code behaves this way see
[ARCHITECTURE.md](./ARCHITECTURE.md); for how to run it see
[RUNBOOK.md](./RUNBOOK.md).

---

## 1. At a glance

There are three screens and one job: find a drug, confirm it is safe to use,
enter an animal's weight, get a volume.

```
                 ┌──────────────────────────────────────┐
   launch ──────►│  Home                                │
                 │  search bar · result count · list    │
                 └───────┬──────────────────┬───────────┘
                         │ tap a result     │ ⚙ / version badge
                         ▼                  ▼
                 ┌────────────────┐  ┌────────────────────┐
                 │  Calculator    │  │  Settings and sync │
                 │  species       │  │  dataset · logs    │
                 │  weight        │  │  server · trust    │
                 │  → result      │  └────────────────────┘
                 └────────────────┘
```

The app has four top-level actions and nothing else: **search**, **open a
drug**, **change the server**, **sync**. There is no account, no onboarding, no
permission prompt, and no network requirement at any point.

---

## 2. Flow — first launch

| Step | What the user sees |
|---|---|
| 1 | A spinner on a white screen. |
| 2 | The gradient app bar appears: a paw icon and **Vetifi**, with the search field docked below it. |
| 3 | Below the search bar: `0 drugs` on the left, `Dataset v14` on the right. |
| 4 | The empty state: a faded pill icon, **Search for a drug**, and *Type at least two letters to search.* |
| 5 | If a server is reachable, a sync banner appears at the top. If not, an offline banner does. |

Behind step 1 the app seeds 50,010 drugs from the bundled asset and builds the
search index. **This needs no network.** The dataset version and the result
count come up together because both are read from the same SQLite file.

The app also attempts one background sync on launch. It is silent about the
attempt until it has an answer, so a user who is offline sees the empty state
first and the offline banner a moment later.

> There is no first-run tour, no "welcome", no permission dialog. The empty
> state *is* the onboarding, and it is one sentence long.

---

## 3. Flow — searching

### 3.1 Typing

The user types into the field in the app bar. Three things happen, in this
order:

1. **Debounce, 120 ms.** Every keystroke resets a timer. Typing `meloquin`
   fast produces exactly one search, not nine. The result count changes to
   `Searching...` with a small spinner immediately, so the app acknowledges
   the keystroke even though it has not searched yet.
2. **Search off the UI thread.** The query runs in an isolate. A slow query
   cannot freeze the list.
3. **Ticket check.** Each search takes a numbered ticket. Results are applied
   only if that ticket is still the newest. A slow query for `mel` cannot land
   after a fast query for `meloquin` and replace the better results with worse
   ones.

Results are capped at 60. The count line reads `60 drugs` even when more
match — the cap is visible as a number, not hidden.

### 3.2 The result row

```
┌──────────────────────────────────────────────────────┐
│  ▣   Meloxicam                                          │
│  ▣   MELOXICAM          ‹                            │
│      [PO]  [5 mg/mL]  🐕 Dog  🐈 Cat                  │
└──────────────────────────────────────────────────────┘
```

| Element | Source | Why it is there |
|---|---|---|
| Leading icon | `medication` / `warning_amber` / `block` | Encodes drug state before any text is read |
| Name | `drug.name` | Struck through when withdrawn |
| ID | `drug.id.toUpperCase()` | Lets a user quote the exact record when reporting a problem |
| Route chip | `drug.route` | `PO`, `IV`, `IM` — how it is given |
| Concentration chip | `drug.concentrationRaw` | The string exactly as published, so `10%` is not silently shown as `100 mg/mL` |
| Species | `drug.availableSpecies` | Tells the user whether this drug even applies to their animal |
| Note line | withdrawal reason or first validation error | The reason, not just the fact |

Colour follows state, and it is the only place colour carries meaning that is
not repeated in text:

| State | Background | Icon | Note |
|---|---|---|---|
| Normal | surface | `medication` | — |
| Has a data issue | warning tint | `warning_amber` | *Data issue detected* |
| Withdrawn | withdrawn tint | `block` | *Withdrawn: {reason}* |

An invalid concentration turns its chip red. The raw text is still shown —
`0 mg/mL` is more useful to a human diagnosing a data problem than a blank.

### 3.3 Search that finds nothing

The empty state changes rather than showing an empty list:

| User typed | Message |
|---|---|
| nothing | **Search for a drug** — *Type at least two letters to search.* |
| something, no matches | **No matching drugs** — *Check the spelling, or try a shorter fragment of the name.* |

### 3.4 Clearing

A `✕` appears in the field once there is text. Tapping it empties the field,
clears the list, and invalidates any in-flight query so a late result cannot
repopulate the screen.

---

## 4. Flow — calculating a dose

Tap any row to open the calculator. The whole screen is one scroll view.

### Step 1 — the drug card

Name, ID, route, concentration, and — when the raw concentration contains a
`%` — the derived value beside it:

```
Route            Concentration        (= mg/mL)     Max Total
PO               10%                   100 mg/mL      500 mg
```

Showing both is deliberate. `10%` is what the label says; `100 mg/mL` is what
the calculator needs. Displaying only the derived number would hide the fact
that a conversion happened.

### Step 2 — species

Chips for every species in the dataset (`Dog`, `Cat`, …). A species whose
entry carries a validation error is shown dimmed with a warning icon and is
still tappable — the app explains the problem rather than hiding the option.

Nothing below this section is visible until a species is chosen. There is no
default, because guessing the species is how a dog gets a cat dose.

Changing species clears any result already on screen.

### Step 3 — weight

A numeric field and a `kg` / `lb` toggle. Changing the unit clears the result.

The toggle does not reinterpret the number — switching from kg to lb leaves the
digits alone. The user is expected to retype, because silently multiplying a
typed weight is the kind of helpfulness that causes a dosing error.

### Step 4 — calculate

A full-width gradient button. Tap, and:

- invalid input → the error appears as a banner below the button
- unusual but plausible weight → a **Check the weight** advisory appears, and
  the result still calculates
- valid → the result card appears

Any edit to the weight or species clears the result immediately. There is no
stale answer sitting on screen next to inputs that no longer produce it.

### Step 5 — the result

The volume is the largest thing on the screen, in a dark result panel:

```
┌──────────────────────────────────────────────┐
│ ✓  Dose Result                        v14    │
│                                              │
│           VOLUME TO ADMINISTER                │
│          2.0 – 4.0 mL                        │
│                                              │
│  Total dose     40 mg                         │
│  Concentration  10 mg/mL                      │
│  Syringe        Use a 3 mL syringe            │
│  Dataset        v14                           │
└──────────────────────────────────────────────┘
```

Advisories stack underneath, in order of seriousness:

| Advisory | When | Severity |
|---|---|---|
| Dose capped at maximum safe limit | Computed dose exceeds `maxTotalMg` | Highest — states both numbers and says to divide the dose |
| Exact value | The rounded number differs from the true one | Shown as a footnote, never as the headline |
| Small volume | Below 1 mL | Recommends a smaller syringe |
| Precision alert | Below 0.1 mL | Recommends a tuberculin syringe and checks graduation |
| Dilute before drawing up | Below 0.01 mL | Should be unreachable — see below |

### CRI branch

If the selected drug and species have a constant-rate infusion entry, extra
inputs appear above the button: **Dose rate (mcg/kg/min)**, **Fluid rate
(mL/hr)**, **Bag size (mL)**. The button relabels to *Constant Rate Infusion
(CRI)*. Results report the volume of drug to add to the bag, the resulting
concentration in the bag, and the bag duration, plus one standing tip:

> Withdraw equivalent volume from bag before injecting drug to preserve precise
> concentration.

That tip is not decoration. Adding drug to a full bag silently dilutes the
fluids the patient is already receiving.

---

## 5. Every path where the app refuses

This is the part that matters most in a clinical tool. A refusal is a feature;
each one below is enforced by a test.

| Situation | What the user sees | Why |
|---|---|---|
| Drug withdrawn | Red **Drug Withdrawn** banner with the reason. No species selector, no weight field, no button. | There is no correct dose for a withdrawn drug |
| Concentration unparseable | Amber **Data Issue** banner: `Invalid concentration: "0 mg/mL". Cannot calculate doses.` | `0/0` is not a dose |
| Unknown or non-mass dose unit | **Cannot Calculate** banner naming the unit | A `g/kg` entry read as `mg/kg` is off by 1000× |
| Species entry invalid | **Cannot Calculate** banner on that species | Failing loudly beats a plausible number |
| Dose unit missing for CRI | CRI section refuses | The whole calculation depends on it |
| Volume below 0.01 mL | **Cannot Calculate**: *below the measurable range of any syringe* | `0.000 mL` is a bug wearing a decimal point's clothes |
| Weight empty or not a number | Field-level error | — |
| CRI dose rate out of range | Field-level error | — |

Two of these are worth calling out because they are judgement calls:

**An unusual weight is an advisory, not a refusal.** A 0.8 kg dog is a real
animal. The app calculates, and adds *Check the weight*. Refusing would have
been safer on paper and useless in the clinic.

**A sub-measurable volume refuses rather than rounding up.** Below 0.01 mL the
correct answer is a smaller syringe or a dilution, and the app says exactly
which. Displaying `0.000 mL` or rounding to `0.01 mL` would both be lies.

---

## 6. Flow — settings and sync

Reached from the gear icon or by tapping the version badge. Five sections.

### Dataset

Installed version · schema version · last checked · dataset age · searchable
drug count. Each shows `unknown` rather than a blank when the app has no value
yet.

### Calculation log

Records waiting to upload, and one sentence of explanation: records are held on
the device until a connection exists, then uploaded in batches. Uploading twice
is harmless because the server deduplicates on record ID.

### Dataset server

A base URL field with the emulator note as helper text, plus **Sync now** and
**Save**.

**Sync now** disables itself and shows a spinner while in flight, so a double
tap cannot start two syncs.

### Trust

A plain statement of what happens on every update — verified against the
Ed25519 key compiled into the build before a single row is written, discarded
on failure, previous dataset kept — followed by the public key itself, in full,
so anyone can check it.

### Footer

`Vetifi 1.0.0 — fictional drugs, not for clinical use`.

### What sync tells the user

| Outcome | Banner | Icon |
|---|---|---|
| Up to date | *Dataset is up to date.* | `cloud_done` |
| New version installed | *Updated to dataset v15.* The list reloads and the badge changes. | `cloud_done` |
| Offline | *Offline. Using the dataset stored on this device.* | `cloud_off` |
| Server unreachable | *Could not reach the dataset server.* | `cloud_off` |
| Signature invalid | *Update refused: the manifest failed signature verification.* | `cloud_off` |
| Payload tampered | *Update refused: the payload did not match the manifest.* | `cloud_off` |
| Version went backwards | *Update refused: the offered dataset is not newer than the installed one.* | `cloud_off` |
| Wrong base | *Update refused: the delta does not apply to the installed version.* | `cloud_off` |
| Unreadable | *Update refused: the dataset could not be read.* | `cloud_off` |

In every refusal case the list on the other side of the back button is
unchanged. The user is told what was refused and keeps working.

### Staleness

Independent of sync, if the installed dataset is old the home screen shows a
persistent advisory above the results:

| Age | Message |
|---|---|
| < 60 days | nothing |
| 60–179 days | *Check for safety revisions when a connection is available.* |
| ≥ 180 days | *This dataset may contain concentrations that have since been corrected.* |

The app cannot force an offline user to update. It can be honest about how old
its data is, which is the part actually within its control.

### Returning from settings

A sync is attempted on the way back, so a user who changed the base URL sees
the result of that change immediately rather than having to guess.

---

## 7. What changes when an update lands

Nothing moves, nothing is deleted, and no screen is interrupted. The list
reloads in place and the badge changes from `v14` to `v15`.

Concretely, after publishing v15:

- **Withdrawn drugs** stay searchable, now struck through and tinted, with the
  withdrawal reason. Tapping one shows the withdrawn banner and offers no
  calculation. A user who remembers a drug still finds it, and finds out why it
  is gone.
- **New drugs** appear in search immediately.
- **Edited drugs** show their new values. Result cards carry the version they
  were computed from, so a number calculated before an update can be
  identified afterwards.

---

## 8. Accessibility and localisation status

| Area | State |
|---|---|
| Kannada strings | Written and complete in `lib/l10n/strings.dart` |
| Language toggle | **Disabled.** The button is commented out in the app bar of both screens and `LanguageController.init()` is not called from `main.dart` |
| Current language | English, not persisted — a relaunch resets it |
| Screen readers | Icons carry tooltips (`Settings and sync`, `Clear`); the result card is text, not canvas-drawn |
| Touch targets | Search field 48 dp, calculate button 52 dp, species chips padded |
| Text scaling | Layouts use `Expanded`, `Wrap`, and `Flexible` rather than fixed heights, so larger system fonts do not clip |
| Colour-only signalling | Every state that uses colour also uses an icon and a word |
| Dark mode | Not implemented |

---

## 9. Known gaps in the user flow

Honest list, because the same reasoning appears in
[BREAK_IT.md](./BREAK_IT.md):

1. **No working language switch.** The Kannada translation exists and is
   unreachable. This is the clearest gap in the product.
2. **No dark mode.** The palette is light-only.
3. **Weight unit toggle does not convert.** Deliberate, but it will read as a
   bug to anyone who does not know that.
4. **The empty state says "type at least two letters" but a single letter
   searches.** The hint is conservative advice; a one-character query does run
   and does return up to 60 results. The copy should either match the behaviour
   or the behaviour should enforce the minimum.
5. **Results cap at 60 with no "show more".** A broad fragment like `cillin`
   silently truncates.
6. **No history.** A calculation disappears when the user navigates back.
7. **No combined-search.** Route, species, and concentration are displayed but
   not searchable or filterable.
8. **No accessibility review with a real screen reader.** Written to be
   compatible; not verified with TalkBack.
9. **Physical-device search latency unmeasured.** The benchmark runs on a
   desktop.

---

## Further reading

- [RUNBOOK.md](./RUNBOOK.md) — running it, the demo script, troubleshooting
- [ARCHITECTURE.md](./ARCHITECTURE.md) — how each of these screens is implemented
- [DECISIONS.md](./DECISIONS.md) — the reasoning behind the clinical thresholds
- [BREAK_IT.md](./BREAK_IT.md) — failure modes and what was deliberately not fixed