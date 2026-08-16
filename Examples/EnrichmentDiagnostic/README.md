# Enrichment Diagnostic

A small SwiftUI app that proves, on a real iPhone, what HealthKit actually exposes for
a workout: the route, workout-associated heart rate, native events, and workout
activities.

This is the Phase 0 device proof. It answers questions that no simulator and no unit
test can answer, because the simulator has no real workouts and HealthKit will not
return route or quantity data without a signed build on a physical device.

**These files are deliberately not part of the Swift package.** `Package.swift` scopes
the target to `Sources/OpenWearablesHealthSDK`, so nothing in `Examples/` is compiled by
`swift build` or `xcodebuild`. Copy them into your own throwaway app target.

## What it does

1. Requests read access for exactly three types: workout, workout route, and heart rate.
2. Lists your recent workouts with identity-free labels (`running — 42:13 — 3 days ago`).
3. Runs the probe on the workout you pick — every route object, every route batch, exact
   workout-associated heart rate, condensed-series expansion, events, and (iOS 16+)
   activities.
4. Shows a **redaction-safe report**: counts, native types seen, elapsed-offset bounds,
   availability states, and 8-hex hash prefixes.
5. Generates a redacted fixture, runs `RedactionGuard` over it, and only then offers a
   share sheet to export it.

## What it never does

- It never displays or exports a coordinate, a heart-rate value, an absolute timestamp,
  a HealthKit UUID, a bundle identifier, or a device name. The report is built only from
  counts, type names, durations, booleans, and hash prefixes.
- It never logs health data. There is no `print` or `NSLog` of anything read.
- It never calls `OpenWearablesHealthSDK.requestAuthorization(types:)`. That method
  replaces the SDK's persisted `trackedTypes` set, so calling it here would silently
  reduce a host app's tracked types to these three and break its core sync. The probe
  issues its own scoped `HKHealthStore` request instead.
- The export is gated on `RedactionGuard` passing. If the guard finds anything, the
  share button does not appear.

## Setup

You need a physical iPhone, an Apple Developer account for signing, and Xcode.

### 1. Create the app target

Xcode → **File → New → Project → iOS → App**.

- Interface: **SwiftUI**
- Language: **Swift**
- Name it anything, e.g. `EnrichmentDiagnostic`
- Minimum deployment target: **iOS 16.0** (the export uses `ShareLink`)

Delete the generated `ContentView.swift` and the generated `…App.swift`.

### 2. Add the local package

**File → Add Package Dependencies… → Add Local…**, then select the root of this
repository (the folder containing `Package.swift`).

When Xcode asks which product to add to your target, choose
**OpenWearablesHealthSDK**.

### 3. Paste the source files

Copy `DiagnosticApp.swift` and `ContentView.swift` from this folder into your app
target. Make sure both are members of the app target in the File Inspector.

### 4. Enable the HealthKit capability

Select the app target → **Signing & Capabilities** → **+ Capability** → **HealthKit**.

Leave "Clinical Health Records" and "Background Delivery" unchecked; the probe needs
neither.

### 5. Add the usage description

Select the app target → **Info**, and add:

| Key | Value |
| --- | --- |
| `NSHealthShareUsageDescription` | `Reads your workout route and heart rate so this diagnostic can report what HealthKit exposes. Nothing leaves your device.` |

`NSHealthShareUsageDescription` is required for reading. `NSHealthUpdateUsageDescription`
is not needed — this app never writes to HealthKit.

Without this key the app crashes the moment authorization is requested.

### 6. Run on a physical device

Select your iPhone as the run destination — **not a simulator**.

The simulator has no real workouts, and even if you seed it, routes and workout-associated
quantity series are not reproduced faithfully. Any conclusion drawn from simulator output
is worthless for this proof.

On first launch, iOS shows the Health permission sheet. **Grant all three toggles.** If
you deny one, Apple makes that indistinguishable from absent data, and the family will
report `not_available_or_not_authorized` — which is the correct behaviour, but not a
useful proof run.

## Reading the report

```
workout: running (raw 37)
duration: 42:13  span: 44:01
identity present: sync_id=no sync_version=no external_uuid=no device=yes tz_offset=yes
schema v1 / canon v1 / root 9f2c1ab4

[route] available — 2841 entries — 3d81ba07
  native types: HKWorkoutRoute
  offsets: +0:00 … +44:01
  route_parts=1  batches=6  with_altitude=2841  with_horizontal_accuracy=2841 …

[heart_rate] available — 512 entries — c1740fe9
  native types: interval, point
  offsets: +0:02 … +43:58
  top_level_samples=7  expanded_from_series=498  intervals=498  points=14 …
```

Things worth noting during the proof:

- **`route_parts`** — more than one means a workout genuinely owns several
  `HKWorkoutRoute` objects. Never assume one.
- **`batches`** — how many `HKWorkoutRouteQuery` callbacks were needed. More than one
  proves that stopping at the first batch would silently truncate the route.
- **`top_level_samples` vs entry count** — a large gap proves HealthKit condensed the
  samples and that `HKQuantitySeriesSampleQuery` expansion is doing real work.
- **`intervals`** — coalesced heart-rate spans. These must stay intervals; fabricating
  point timestamps inside them would invent data.
- **`native types`** under `[events]` — whether the recorder emitted `lap`, `segment`,
  `marker`, or only pauses. Do not assume an Apple Workout user marker is a lap.
- **`zero_duration`** — legacy lap markers with no duration.

## Exporting a fixture

Tap **Generate fixture**. The app builds the redacted JSON, runs `RedactionGuard` over
the bytes, and shows the guard result.

- **PASS** → the share button appears. Export it and commit it as a test fixture.
- **FAIL** → no share button. The guard names the category and a non-sensitive location
  (never the value itself). That is a bug in the fixture writer; fix it before exporting.

Redaction applied to the fixture:

- Route coordinates are translated so the first point is `(0, 0)` and then rotated by an
  angle derived from a per-install key. Pairwise distances, turn angles, and gap
  structure survive; the real location does not.
- Timestamps are rebased onto `2000-01-01T00:00:00Z`, preserving every elapsed offset
  and gap exactly.
- UUIDs, sync/external identifiers, source bundle ids and names, and device fields become
  keyed-SHA-256 tokens — stable for the same input and key, not reversible without it.
- Free-text metadata is tokenised; numeric metadata is kept because it is structural.

The redaction key is a random value generated on first launch and stored in
`UserDefaults`. Regenerating a fixture from the same workout on the same install
produces byte-identical output. Reinstalling produces a new key, and therefore different
synthetic identifiers.

The fixture is written to the app's temporary directory with
`NSURLIsExcludedFromBackupKey` set so it cannot enter an iCloud or device backup.

## What this proof still has to establish

Running this app on one workout is not the whole exit gate. The Phase 0 gate also needs:

- An Apple Watch outdoor run recorded by Apple's own Workout app.
- The same run compared against a workout from a third-party iOS recorder, to see the
  real differences in what each source saves.
- A summary-only third-party workout (no route, no detailed samples).
- An indoor workout with no route.
- A workout whose route arrives after the workout was first saved.
- An older workout whose quantities HealthKit has since condensed.
- A background-wake probe on a supported device, to test whether a route can directly
  wake the app — treat a positive result as an unverified optimization, never as
  something the production design depends on.
