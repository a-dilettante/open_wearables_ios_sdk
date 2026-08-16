# Changelog

## Unreleased

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
