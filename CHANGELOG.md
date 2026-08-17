# Changelog

## 0.15.0

### Workout-detail enrichment (additive pipeline)

New opt-in pipeline that publishes workout-owned routes, heart-rate streams, events,
and activities to OW as immutable generations. It runs beside the core sync engine and
never inside it: the round-robin, its 100/2,000 budgets, its anchors, and its
serializers are untouched, and an enrichment pass is skipped outright whenever a core
sync is running.

* **Public API**: `setWorkoutDetailEnrichmentEnabled(_:)`,
  `requestWorkoutDetailAuthorization()`, `getWorkoutDetailEnrichmentStatus()`, and
  `startWorkoutDetailEnrichmentPass()`. Authorization asks `HKHealthStore` directly for
  workout + workout route + heart rate; it never routes through
  `requestAuthorization(types:)`, which replaces the SDK's persisted tracked-type set
  and would silently shrink a host app's core sync. The status dictionary carries counts,
  low-cardinality error classes, and historical progress — no identifier, coordinate,
  sample value, or file name.
* **Independent discovery**: an enrichment-owned `HKQueryAnchor` on `workoutType`, stored
  in the detail checkpoint rather than alongside the core anchors. It advances only in the
  same checkpoint write that persists the jobs and tombstones the query produced, and
  `resetAnchors()` deliberately leaves it alone — a global anchor reset must never be how
  a device discovers newly supported detail.
* **Bounded collection**: two workouts enriched at a time through the Phase 0 reader.
  Late-route reconciliation re-reads workouts published with a pending or absent route for
  14 days, so a route written after its workout is picked up on the next foreground or
  workout-observer wake. Historical enrichment walks 7-day windows newest-first across a
  90-day lookback, resumable from a durable cursor.
* **File-backed staging**: per-upload directory holding a manifest and gzipped columnar
  chunks, bounded by measured serialized bytes (1 MiB target) *and* point count (16,384).
  Chunk bodies are hand-serialized at fixed precision so the same workout always produces
  identical bytes; checksums cover the uncompressed form, which is what the server
  re-derives after inflating. Every file is excluded from backup, marked
  complete-until-first-user-authentication, and removed on terminal receipt, sign-out,
  user switch, disable, or 7-day expiry.
* **Transport**: `PUT` manifest → `PUT` chunks through the existing background
  `URLSession` from files → `POST` complete → `GET` receipt. A workout is recorded as
  published or noop **only** on that terminal receipt; HTTP acceptance of chunks is not
  publication. A 404 means the server feature flag is off and defers with backoff while
  keeping all durable state — never a dead letter. A manifest 409 fails permanently; a
  chunk 409 re-derives the upload from a fresh read; 401 reuses the existing token
  refresh. Background task descriptions carry an 8-hex upload-id prefix and a file name
  only — no path, user id, or workout identity.
* **Never clears published data**: a family with no points is omitted from the manifest
  rather than sent empty, because an empty HealthKit read is indistinguishable from a
  denied one and an empty family could be read as a deletion. A workout with no route
  still publishes its heart rate, events, and activities.
* **Honest reduction**: heart rate is published for one source per stream (a watch and a
  chest strap are never merged into one fabricated sensor) and an event type the contract
  cannot express is dropped rather than flattened into a neighbouring type. Both cases
  report the family as `partial`.
* **Per-user isolation**: the checkpoint and staged files are deleted on sign-out and when
  signing in as a different user. There is no cross-account recovery path.
* **Telemetry** on the existing `/logs` channel: pass start/end with counts by family,
  byte totals, durations, and error classes. No identifiers, no coordinates.
* **Integration seams** are four one-line hooks plus an `"enrich|"` prefix branch in the
  URL-session delegate. No new `HKObserverQuery` type is registered and routes are
  deliberately not observed — direct route background wakes are unverified, so late routes
  rely on workout observers and foreground reconciliation.

### Workout-detail capture harness (Phase 0)

* **Workout-detail capture harness (Phase 0, additive)**: new `Internal/WorkoutDetail/` reads HealthKit workout routes, workout-associated heart rate, native events, and iOS 16+ workout activities into typed models. Routes are read via the workout-association predicate across every `HKWorkoutRouteQuery` batch and every route object; heart rate uses the workout-association predicate (never a time window) and expands condensed samples with `HKQuantitySeriesSampleQuery`, preserving interval semantics. Each family reports its own availability (`available`/`partial`/`pending_enrichment`/`not_available_or_not_authorized`/`invalid`) — never a permission outcome, which Apple does not expose.
* **Deterministic family hashing**: canonical serialization plus SHA-256 hashes per family and a root hash. Ordering is by elapsed offset then ordinal; no absolute timestamp enters a hash.
* **Redacted fixture writer and guard**: fixtures translate and rotate route coordinates to a synthetic origin, rebase timestamps onto `2000-01-01T00:00:00Z` preserving all offsets and gaps, and replace identifiers with keyed SHA-256 tokens. `RedactionGuard` scans the produced bytes and fails if any original coordinate, timestamp, UUID, source, or device value survives.
* **`WorkoutDetailProbe`**: standalone probe with its own scoped `HKHealthStore` authorization request for workout + workout route + heart rate. It deliberately does not call `requestAuthorization(types:)`, which would replace the SDK's persisted tracked-type set. Its report contains only counts, native types, elapsed-offset durations, and 8-hex hash prefixes.
* **`Examples/EnrichmentDiagnostic/`**: SwiftUI device diagnostic (outside the SPM target) for the physical-device proof.
* **CoreLocation** added to the linked frameworks in `Package.swift` and the podspec, for `CLLocation` route points.

No existing sync, serialization, or authorization behaviour changed.

## 0.14.0

* **Fixed full export poisoning**: when the first upload of a full export failed (offline, backend down, app killed), subsequent triggers overwrote the session as incremental without anchors — causing an infinite re-upload loop of old data. Full-export mode is now sticky until completed; already-poisoned devices self-heal.
* **Fixed anchor loss on capture errors**: anchor capture silently swallowed errors (e.g. locked device) and ignored deleted objects in pagination, marking types as complete with a missing/stale anchor. Errors now pause sync; deleted objects count toward query limits.
* **Hardened outbox retries**: retries moved from parallel foreground requests to a serialized background `URLSession` (survives app kill, 1 connection per host). Payloads are preserved on transient failures, dropped on 4xx, expired after 7 days.
* **Background time management**: sync pauses before background time runs out instead of getting killed mid-upload. New `didBecomeActive` observer resumes sync immediately when the app returns to foreground.
* **New `getSyncStatus()` fields**: `initialExportDone` (Bool) and `isSyncing` (Bool) — allows apps to show progress UI during the initial historical export.
* **Removed dead code**: legacy per-type sync path (`syncType`, `enqueueBackgroundUpload`, `chunkSize`).

## 0.13.0

* **Sync telemetry**: new `/logs` endpoint integration for initial full sync diagnostics.
  - `historical_data_sync_start` event sent before the first payload with per-type record counts, time range, and device state.
  - `historical_data_type_sync_end` event sent per data type as each completes (fire-and-forget), with record count, duration, success status, and device state snapshot.
  - Device state includes battery level/state, thermal state, low power mode, RAM usage, and foreground/background task type.
  - Types with zero records are excluded from end events.
  - Start event is sent for both fresh and resumed full exports.

## 0.12.0

* **Source device name**: added `name` field to the source object in health data payloads, providing human-readable device identification alongside existing device metadata.

## 0.11.0

* **Smarter token refresh error handling**: token refresh failures are now classified as either `authFailure` (refresh token rejected with 401/403) or `networkError` (timeout, DNS, 5xx). Only genuine auth failures trigger user disconnect — transient network errors during refresh no longer force sign-out, allowing the SDK's retry mechanism to recover automatically.

## 0.10.0

* **Combined payloads**: all health data types are now merged into a single payload per sync round instead of separate requests per type.
* **Interleaved sync**: data is fetched round-robin across all types (newest to oldest) instead of sequentially type-by-type.
* **Streaming JSON serialization**: payloads are serialized directly to the network stream, reducing memory usage from O(n) to O(depth).
* **Token refresh fix**: fixed stale credential being reused across sync rounds after a token refresh — credential is now read fresh from Keychain before each upload.
* **Bearer prefix normalization**: access tokens returned by the refresh endpoint without the `Bearer ` prefix are now handled correctly.
* **Sign-out reliability**: `signOut()` now guarantees state cleanup even if the native call throws.
* **Cleaned up logging**: removed verbose debug logs and all token/credential values from log output. Logs now show only essential sync lifecycle events, payload summaries, and HTTP statuses.

## 0.9.0

* Initial tracked release.
