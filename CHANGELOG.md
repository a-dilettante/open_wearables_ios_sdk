# Changelog

## 0.15.0-circle.1 (Circle fork — not released upstream)

* **Acknowledged per-user sync anchors survive sign-in and sign-out (Circle)**: `signIn` and `signOut` no longer call `resetAllAnchors()`. Anchor keys and the initial-export-complete marker are scoped to the OW user id, so re-signing into the same account resumes from its acknowledged anchors instead of triggering a full re-export, and a different user cannot read them. Sign-out still cancels sync, stops observers and background tasks, and clears credentials, the sync session, the outbox, and enrichment state. The explicit `resetAnchors()` API remains destructive.

* **Restored `syncNow(completion:)`**: the 0.14.0 rework removed it with the legacy per-type path, breaking the RN wrapper's existing bridge. It is back as a thin wrapper over an incremental sync round, safe to call mid-sync.

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
* **CoreLocation** added to the linked frameworks in `Package.swift` for `CLLocation` route points (the podspec is left as upstream has it; Swift autolinks the framework on import).

No existing sync, serialization, or authorization behaviour changed.

## Unreleased

* **Cycling power and cadence** (#44): authorize and sync `cyclingPower`, `cyclingCadence`, `cyclingSpeed`, and `cyclingFunctionalThresholdPower` (iOS 17+) as quantity samples — the same path as `heartRate` / `runningPower` — so Bluetooth power-meter timeseries and Apple Watch cycling workouts actually reach the backend. Workout-level averages for power, cadence and speed are populated from `HKWorkout` statistics.
* **Running dynamics** (#13): authorize and sync `runningPower`, `runningVerticalOscillation`, and `runningGroundContactTime` (iOS 16+) as quantity samples — the same path as `heartRate` — so workout-level averages and per-sample timeseries actually reach the backend. Workout `laps` are now populated from `HKWorkout.workoutEvents` (lap / segment / marker) instead of always `null`.
* **Background token refresh after relaunch** (#18): restore the persisted host on SDK `init` and fall back to it in `apiBaseUrl`, so a HealthKit / `BGTask` / background `URLSession` cold start can refresh an expired session before the host app calls `configure(host:)` again.
* **Configurable token-refresh URL**: `configure(host:tokenRefreshURL:)` accepts an optional absolute refresh endpoint for deployments whose auth/mint server is not the sync host. Omitted or blank keeps `{host}/api/v1/token/refresh`. The override is persisted so a background `BGTask` in a fresh process can refresh before `configure` runs again. Request/response contract is unchanged (`POST {"refresh_token"}` → `{"access_token","refresh_token"}`).
* **Fixed sync cancellation races** (#26): `cancelSync()` used to set its cancel flag, clear `isSyncing` and reset the flag synchronously, so a running loop could miss the whole cancellation window while a second sync started on top of it. Runs are now identified by a generation counter, the flag is never reset behind a live run, and the slot is released only when the loop actually unwinds (with a 60s takeover for a wedged run).
* **Cancellation no longer kills unrelated requests** (#26): sync uploads are tracked individually and cancelled by identity, instead of cancelling every task on the shared foreground session — which also aborted token refreshes (surfacing as `.networkError`) and telemetry.
* **No more duplicate replays from the outbox** (#27): the sync path no longer writes outbox items. They carried no anchors and no progress deltas, so a successful replay re-sent records that `SyncState` had already counted. `SyncState` is now the single source of resumable progress; leftover items from older versions are still drained and cleaned up.
* **Background chunk size is decided by app state** (#24): observer-driven syncs, unlock resumes and network resumes ran with the 2000-record foreground chunk (~1.3 MB) while the app was in the background. The chunk size is now re-evaluated every round from the actual app state.
* **Lower peak memory per upload** (#28): the payload is no longer written to disk and read back before being sent, and `logPayloadSummary` no longer re-parses the whole payload when logging is disabled (the default in release builds).
* **Upload failures are visible** (#29): `NSURLErrorCancelled` is no longer suppressed. Every upload now records request id, declared bytes, `countOfBytesSent` against `countOfBytesExpectedToSend`, HTTP status, error domain/code and, for a cancellation, whether it came from `cancelSync()`, background expiration or the system. Failures are logged at a level that survives release builds.
* **Request attribution headers** (#30): every SDK request now sends `X-Open-Wearables-SDK-Version`, `X-Open-Wearables-SDK-Platform`, a `User-Agent` with SDK version, iOS version and device model, and a per-request `X-Request-Id` (reused across a 401 retry). Outbox uploads also send `X-Open-Wearables-Outbox-Item`.
* **Removed the manual `Content-Length` header** (#32), which is reserved and managed by Foundation, and the unused `bufferLock` (#33).
* **Dropped the unused legacy serializer** (#28): `serializeCombined` and the five mappers only it called (`_mapWorkout`, `_mapQuantity`, `_mapCategory`, `_mapSleep`, `_mapCorrelation`) had no call sites and duplicated the `*Efficient` variants that actually run. `serializeCombinedStreaming` is renamed to `buildCombinedPayload`, because it never streamed: the payload is built as a dictionary tree and serialized in one piece. Peak memory is bounded by round size instead - background rounds carry 100 records (~65 KB) since #24, and 2000-record rounds only run in the foreground.
* **Background `URLSession` scope is now explicit** (#25): the legacy per-type path that fed it (`syncType` / `enqueueBackgroundUpload`) is gone and the sync path no longer writes outbox items, so the session exists only to drain leftovers from installs that upgraded from an earlier version. Removed the `newPath` / `ensureOutboxDir` helpers that nothing called, and documented that `setBackgroundCompletionHandler` is never invoked once those leftovers are drained. Sync uploads stay on the foreground session: an interrupted round costs rebuilt work, not lost data, because `SyncState` only advances on a 2xx.
* **HTTP 4xx no longer advances sync progress**: a 400 (including the production `ClientDisconnect`) fails the chunk so cursors stay put and the next wake rebuilds the payload. Cancelled or superseded sync generations do not write `SyncState`. Late outbox callbacks after `signOut` are ignored.
* **Sync session tracking** (#41): every `/sync` batch now carries `syncSessionId` and `syncType` (`historical` | `live`), and every `/logs` body carries the same `syncSessionId`. The id lives on `SyncState` so a resume after process death stays on one backend `SyncRun` instead of looking like a new export. A state file written before the field existed still loads; the next attribution fills the id in. `syncType` stays off the logs body because that schema does not accept it yet.
* **`signOut()` tells the backend the user disconnected** (#39): it used to clear local state and nothing else, so the connection stayed `active` with a `last_synced_at` that never moved again and was indistinguishable from a healthy one. It now sends `DELETE {apiBaseUrl}/users/{userId}/connections/apple` before any credential is cleared. Best effort with a 10s timeout: the task is not registered as a sync upload, so the `cancelSync()` inside `signOut` does not cancel it, and a network error, timeout or rejection still signs the user out locally. Nothing is sent when there is no session, and `signOut()` keeps its synchronous signature, so the Flutter and React Native wrappers need no changes. Revoked HealthKit permission and app deletion still cannot be reported.
* **Test coverage for uploads, cancellation and the outbox drain** (#34): none of this was reachable from a test before. An XCTest bundle has no keychain access group, so the SDK could never hold a credential and every authenticated path bailed out early; the state directories were also hardcoded to Application Support, so a test would have read and deleted the host app's state. Two internal seams fix that — `stateDirectoryOverride` redirects the outbox and `SyncState` directories, and `OpenWearablesHealthSdkKeychain.volatileStore` swaps the Keychain for an in-memory store. Both are nil in production. With those in place there are now 16 tests over the combined upload (2xx advances, 4xx / 5xx / transport failures do not, a 401 refreshes once and replays the chunk under the same request id, a rejected refresh surfaces `onAuthError`, a cancelled run never reports success), the run-generation rules (no second run on a live slot, cancel keeps the slot until the loop unwinds, a superseded run cannot release it, cancellation spares untracked requests), and the drain of pre-0.14 leftovers (stale items dropped, orphaned metadata cleaned up, fresh items and overlapping passes skipped).

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
