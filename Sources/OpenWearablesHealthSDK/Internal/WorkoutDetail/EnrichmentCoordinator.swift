import Foundation
import UIKit
import HealthKit

/// Orchestrates workout-detail enrichment beside the core sync engine.
///
/// It owns its own discovery anchor, its own outbox, and its own checkpoint, and it
/// never touches the core round-robin, its budgets, or its anchors. A pass is skipped
/// entirely while a core sync is running, so enrichment can never starve or delay the
/// engine that ships the primary health record.
final class EnrichmentCoordinator {

    /// How many workouts are enriched simultaneously. HealthKit route reads are
    /// memory-hungry and this runs on phones during background wakes.
    static let concurrency = 2
    /// Workouts discovered per pass, so one pass stays bounded on a large archive.
    static let discoveryLimit = 200
    /// A published workout whose route never arrived stays eligible for re-reading for
    /// this long; past it, the source almost certainly never recorded one.
    static let reconciliationWindow: TimeInterval = 14 * 24 * 3600
    /// Terminal jobs older than this are pruned to bound the checkpoint's size.
    static let jobRetention: TimeInterval = 180 * 24 * 3600

    private unowned let sdk: OpenWearablesHealthSDK
    private let healthStore: HKHealthStore
    private let reader: WorkoutDetailReader
    private let outbox: EnrichmentOutbox
    private let checkpoint: EnrichmentCheckpointStore
    private let uploader: EnrichmentUploader

    private let passLock = NSLock()
    private var isPassRunning = false
    private var lastPassStartedAt: Date?

    init(
        sdk: OpenWearablesHealthSDK,
        healthStore: HKHealthStore,
        outbox: EnrichmentOutbox,
        checkpoint: EnrichmentCheckpointStore,
        uploader: EnrichmentUploader
    ) {
        self.sdk = sdk
        self.healthStore = healthStore
        self.reader = WorkoutDetailReader(healthStore: healthStore)
        self.outbox = outbox
        self.checkpoint = checkpoint
        self.uploader = uploader
    }

    // MARK: - Authorization

    /// The three read types the first slice needs.
    ///
    /// Requested directly against `HKHealthStore`, never through
    /// `requestAuthorization(types:)`, which replaces the SDK's persisted tracked-type
    /// set and would silently shrink a host app's core sync to these three types.
    static func readTypes() -> Set<HKObjectType> {
        WorkoutDetailProbe.probeReadTypes()
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        let completed: Bool = await withCheckedContinuation { continuation in
            healthStore.requestAuthorization(toShare: nil, read: Self.readTypes()) { completed, _ in
                continuation.resume(returning: completed)
            }
        }
        checkpoint.mutate(userKey: sdk.userKey()) { $0.hasRequestedAuthorization = true }
        // Apple never reveals whether a read type was granted, so `true` only means the
        // sheet finished — it is not a promise that data will arrive.
        return completed
    }

    // MARK: - Pass

    /// Runs one enrichment pass. Debounced, single-flight, and yields to core sync.
    func runPass(reason: String, debounce: TimeInterval = 0, completion: (() -> Void)? = nil) {
        guard shouldStartPass(debounce: debounce) else {
            completion?()
            return
        }

        Task { [weak self] in
            guard let self else { return }
            await self.performPass(reason: reason)
            self.finishPass()
            completion?()
        }
    }

    private func shouldStartPass(debounce: TimeInterval) -> Bool {
        // Never compete with the core loop for HealthKit or the network. The next
        // trigger (sync completion, foreground, observer wake) picks this up.
        guard !sdk.isSyncInProgress else { return false }

        passLock.lock()
        defer { passLock.unlock() }
        guard !isPassRunning else { return false }

        if debounce > 0, let last = lastPassStartedAt, Date().timeIntervalSince(last) < debounce {
            return false
        }

        isPassRunning = true
        lastPassStartedAt = Date()
        return true
    }

    /// Releases the single-flight latch.
    ///
    /// Both sides of the latch live in a synchronous method on purpose. Taking an
    /// `NSLock` directly inside the pass `Task` blocks a cooperative thread and is an
    /// error under the Swift 6 language mode; keeping the critical section — two field
    /// writes, no I/O — outside the asynchronous context avoids both.
    private func finishPass() {
        passLock.lock()
        defer { passLock.unlock() }
        isPassRunning = false
    }

    private func performPass(reason: String) async {
        let userKey = sdk.userKey()
        let state = checkpoint.load(userKey: userKey)

        guard state.isEnabled, sdk.hasAuth, sdk.userId != nil, HKHealthStore.isHealthDataAvailable() else { return }

        // HealthKit refuses reads while the device has not been unlocked since boot.
        // Deferring here (rather than reading and getting empty results) is what stops a
        // locked phone from publishing an empty family over good data.
        guard await isProtectedDataAvailable() else {
            sendTelemetry(event: "enrichment_pass_skipped", fields: ["reason": reason, "cause": "protected_data_unavailable"])
            return
        }

        let started = Date()
        sendTelemetry(event: "enrichment_pass_start", fields: ["reason": reason])

        outbox.expireStaleUploads()

        await discoverChanges()
        await enqueueHistoricalWindow()
        reconcileLateRoutes()
        pruneExpiredJobs()

        let collected = await collectPendingJobs()
        resumeInFlightUploads()
        flushDueTombstones()

        let finalState = checkpoint.load(userKey: userKey)
        sendTelemetry(event: "enrichment_pass_end", fields: [
            "reason": reason,
            "durationMs": Int(Date().timeIntervalSince(started) * 1000),
            "collected": collected.workouts,
            "routePoints": collected.routePoints,
            "heartRatePoints": collected.heartRatePoints,
            "uncompressedBytes": collected.bytes,
            "countsByState": finalState.jobCountsByState,
            "routePending": finalState.routePendingCount,
            "errorClasses": finalState.errorClasses,
            "historicalProgress": finalState.historicalCursor.map { Int($0.progress * 100) } ?? 0
        ])
    }

    // MARK: - Discovery

    /// Anchored discovery of new and deleted workouts.
    ///
    /// The anchor advances **only** inside the same checkpoint write that persists the
    /// jobs and tombstones the query produced. Writing them separately would let a crash
    /// in between move the anchor past work that was never queued, losing those workouts
    /// permanently — HealthKit will not report them again.
    private func discoverChanges() async {
        let userKey = sdk.userKey()
        var state = checkpoint.load(userKey: userKey)

        if state.historicalCursor == nil {
            let cursor = EnrichmentHistoricalCursor()
            checkpoint.mutate(userKey: userKey) { $0.historicalCursor = cursor }
            state.historicalCursor = cursor
        }
        let boundary = state.historicalCursor?.earliestBoundary
            ?? Date().addingTimeInterval(-EnrichmentHistoricalCursor.defaultLookback)

        let anchor = state.discoveryAnchor.flatMap(Self.decodeAnchor)
        let result: (added: [HKWorkout], deleted: [HKDeletedObject], anchor: HKQueryAnchor?)
        do {
            result = try await runAnchoredWorkoutQuery(anchor: anchor, since: boundary)
        } catch {
            // A failed or partial query must never advance the anchor.
            return
        }
        guard let newAnchor = result.anchor else { return }

        let now = Date()
        let identities = result.added.map { EnrichmentIdentityEnvelope(reader.makeIdentity($0)) }
        let deletedUUIDs = result.deleted.map { $0.uuid.uuidString }

        checkpoint.mutate(userKey: userKey) { state in
            for identity in identities {
                let key = identity.identityKey
                if var existing = state.jobs[key] {
                    // A HealthKit edit is a delete plus a replacement, so re-appearing
                    // content is re-enriched rather than assumed unchanged.
                    existing.identity = identity
                    existing.state = .pending
                    existing.nextAttemptAt = nil
                    existing.updatedAt = now
                    state.jobs[key] = existing
                } else {
                    state.jobs[key] = EnrichmentJob(identity: identity, now: now)
                }
            }

            for uuid in deletedUUIDs {
                // Only workouts whose identity envelope was stored can be tombstoned.
                // Inventing an envelope for an unknown UUID would ask the server to
                // delete something this device never published.
                guard let entry = state.jobs.first(where: { $0.value.identity.healthKitWorkoutUUID == uuid }) else { continue }
                state.tombstones[entry.key] = EnrichmentTombstone(identity: entry.value.identity, deletedAt: now)
                if let uploadID = entry.value.uploadID { outbox.remove(uploadID: uploadID) }
            }

            // Same write, same transaction boundary as the work above.
            state.discoveryAnchor = Self.encodeAnchor(newAnchor)
        }
    }

    /// One bounded, resumable historical window, newest first.
    private func enqueueHistoricalWindow() async {
        let userKey = sdk.userKey()
        guard var cursor = checkpoint.load(userKey: userKey).historicalCursor, !cursor.isComplete else { return }

        let windowStart = cursor.windowStart
        let windowEnd = cursor.windowEnd

        let workouts: [HKWorkout]
        do {
            workouts = try await runWorkoutRangeQuery(from: windowStart, to: windowEnd)
        } catch {
            // Leave the cursor untouched so the same window is retried.
            return
        }

        let now = Date()
        let identities = workouts.map { EnrichmentIdentityEnvelope(reader.makeIdentity($0)) }
        cursor.advance()

        checkpoint.mutate(userKey: userKey) { state in
            for identity in identities {
                let key = identity.identityKey
                // Never disturb a workout already published or already queued.
                if state.jobs[key] == nil {
                    state.jobs[key] = EnrichmentJob(identity: identity, now: now)
                }
            }
            state.historicalCursor = cursor
        }
    }

    // MARK: - Late-route reconciliation

    /// Re-queues recently published workouts whose route had not arrived yet.
    ///
    /// A source may write the route minutes or hours after the workout, and no route
    /// observer is registered (direct route background wakes are unverified), so this
    /// foreground/observer-triggered sweep is how a late route is noticed.
    private func reconcileLateRoutes() {
        let now = Date()
        checkpoint.mutate(userKey: sdk.userKey()) { state in
            for (key, job) in state.jobs {
                if state.heartRateOnly {
                    guard (job.state == .published || job.state == .noop),
                          now.timeIntervalSince(job.workoutEndDate) >= 0,
                          now.timeIntervalSince(job.workoutEndDate) < Self.reconciliationWindow else { continue }
                    if now.timeIntervalSince(job.updatedAt) > 900 {
                        var updated = job
                        updated.state = .pending
                        updated.updatedAt = now
                        state.jobs[key] = updated
                    }
                    continue
                }
                guard job.state == .published || job.state == .noop,
                      let availability = job.routeAvailabilityAtLastPublish,
                      availability == WorkoutDetailAvailability.pendingEnrichment.rawValue
                        || availability == WorkoutDetailAvailability.notAvailableOrNotAuthorized.rawValue,
                      now.timeIntervalSince(job.workoutEndDate) < Self.reconciliationWindow else { continue }

                var updated = job
                updated.state = .pending
                updated.updatedAt = now
                state.jobs[key] = updated
            }
        }
    }

    private func pruneExpiredJobs() {
        let cutoff = Date().addingTimeInterval(-Self.jobRetention)
        checkpoint.mutate(userKey: sdk.userKey()) { state in
            state.jobs = state.jobs.filter { _, job in
                !(job.isTerminal && job.workoutEndDate < cutoff)
            }
        }
    }

    // MARK: - Collection

    private struct CollectionTotals {
        var workouts = 0
        var routePoints = 0
        var heartRatePoints = 0
        var bytes = 0
    }

    private func collectPendingJobs() async -> CollectionTotals {
        let userKey = sdk.userKey()
        let now = Date()

        let due = checkpoint.load(userKey: userKey).jobs
            .filter { Self.isDueForCollection($0.value, now: now) }
            // Newest workouts first: recent activity is what a user is looking at.
            .sorted { $0.value.workoutEndDate > $1.value.workoutEndDate }
            .map { $0.key }

        var totals = CollectionTotals()
        guard !due.isEmpty else { return totals }

        for slice in due.chunked(into: Self.concurrency) {
            await withTaskGroup(of: CollectionTotals?.self) { group in
                for key in slice {
                    group.addTask { [weak self] in await self?.collectAndStage(identityKey: key) }
                }
                for await result in group {
                    guard let result else { continue }
                    totals.workouts += result.workouts
                    totals.routePoints += result.routePoints
                    totals.heartRatePoints += result.heartRatePoints
                    totals.bytes += result.bytes
                }
            }
        }
        return totals
    }

    /// Reads one workout, stages its upload, and starts the transfer.
    private func collectAndStage(identityKey: String) async -> CollectionTotals? {
        let userKey = sdk.userKey()
        guard let job = checkpoint.load(userKey: userKey).jobs[identityKey],
              let uuidString = job.identity.healthKitWorkoutUUID,
              let uuid = UUID(uuidString: uuidString) else { return nil }

        checkpoint.mutate(userKey: userKey) { state in
            guard var current = state.jobs[identityKey] else { return }
            current.state = .collecting
            current.updatedAt = Date()
            state.jobs[identityKey] = current
        }

        let workout: HKWorkout
        do {
            workout = try await reader.fetchWorkout(uuid: uuid)
        } catch {
            // The workout is gone or unreadable. It is not failed — a deletion arrives
            // through the anchored query as a tombstone, and a locked device recovers.
            markDeferred(identityKey: identityKey, errorClass: "workout_unavailable")
            return nil
        }

        let heartRateOnly = checkpoint.load(userKey: userKey).heartRateOnly
        let collected = heartRateOnly
            ? await reader.collectHeartRateOnly(for: workout)
            : await reader.collectDetail(for: workout)
        let prepared = EnrichmentPreparation.prepare(collected)
        let routeAvailability = heartRateOnly
            ? WorkoutDetailAvailability.notAvailableOrNotAuthorized
            : EnrichmentPreparation.routeAvailability(
                prepared.detail.route,
                workoutEnd: prepared.detail.identity.endDate
            )

        // Nothing to publish and nothing pending: an indoor workout from a summary-only
        // source. Recording it as noop stops it being re-read every pass.
        let hasContent = prepared.detail.route.pointCount > 0
            || !prepared.detail.heartRate.entries.isEmpty
            || !prepared.detail.events.events.isEmpty
            || !prepared.detail.activities.activities.isEmpty
        guard hasContent || routeAvailability == .pendingEnrichment else {
            checkpoint.mutate(userKey: userKey) { state in
                guard var current = state.jobs[identityKey] else { return }
                current.state = .noop
                current.routeAvailabilityAtLastPublish = routeAvailability.rawValue
                current.updatedAt = Date()
                state.jobs[identityKey] = current
            }
            return nil
        }

        let staged: StagedEnrichmentUpload
        do {
            staged = try outbox.stage(detail: prepared.detail, routeAvailability: routeAvailability)
        } catch {
            markDeferred(identityKey: identityKey, errorClass: "staging_failed")
            return nil
        }

        checkpoint.mutate(userKey: userKey) { state in
            guard var current = state.jobs[identityKey] else { return }
            current.state = .uploading
            current.uploadID = staged.uploadID
            current.rootHash = staged.rootHash
            current.familyHashes = staged.familyHashes
            current.lastErrorClass = nil
            current.updatedAt = Date()
            state.jobs[identityKey] = current
        }

        uploader.advance(uploadID: staged.uploadID, identityKey: identityKey)

        return CollectionTotals(
            workouts: 1,
            routePoints: staged.routePointCount,
            heartRatePoints: staged.heartRatePointCount,
            bytes: staged.totalUncompressedBytes
        )
    }

    /// Backs a job off after a failure during **collection**, and leaves it collectable.
    ///
    /// A collection-phase failure happens before there is an upload id, so the job has to
    /// go back to `pending`: `deferred` is the upload-phase state, and the only thing that
    /// revisits a deferred job is `resumeInFlightUploads`, which needs an upload id to
    /// nudge. A job parked in `deferred` with no upload id would be picked up by neither
    /// loop and would sit in the checkpoint until it was pruned, never retried.
    ///
    /// `nextAttemptAt` is what makes this a back-off rather than a hot loop, and
    /// ``isDueForCollection(_:now:)`` is the one place it is honoured.
    static func deferCollection(_ job: EnrichmentJob, errorClass: String, now: Date = Date()) -> EnrichmentJob {
        var updated = job
        updated.state = .pending
        updated.uploadID = nil
        updated.attemptCount += 1
        updated.lastErrorClass = errorClass
        updated.nextAttemptAt = now.addingTimeInterval(EnrichmentUploader.backoff(attempt: updated.attemptCount))
        updated.updatedAt = now
        return updated
    }

    /// Whether a job is waiting to be read from HealthKit and its back-off has elapsed.
    static func isDueForCollection(_ job: EnrichmentJob, now: Date) -> Bool {
        guard job.state == .pending else { return false }
        if let next = job.nextAttemptAt, next > now { return false }
        return true
    }

    private func markDeferred(identityKey: String, errorClass: String) {
        checkpoint.mutate(userKey: sdk.userKey()) { state in
            guard let current = state.jobs[identityKey] else { return }
            state.jobs[identityKey] = Self.deferCollection(current, errorClass: errorClass)
        }
    }

    // MARK: - Resume and tombstones

    /// Nudges every upload that has staged files but no receipt yet.
    private func resumeInFlightUploads() {
        let now = Date()
        let jobs = checkpoint.load(userKey: sdk.userKey()).jobs

        for (key, job) in jobs {
            guard let uploadID = job.uploadID,
                  job.state == .uploading || job.state == .awaitingReceipt || job.state == .deferred,
                  (job.nextAttemptAt ?? .distantPast) <= now else { continue }
            uploader.advance(uploadID: uploadID, identityKey: key)
        }
    }

    private func flushDueTombstones() {
        let now = Date()
        for (key, tombstone) in checkpoint.load(userKey: sdk.userKey()).tombstones {
            guard (tombstone.nextAttemptAt ?? .distantPast) <= now else { continue }
            uploader.sendTombstone(identityKey: key, tombstone: tombstone)
        }
    }

    // MARK: - HealthKit plumbing

    private func runAnchoredWorkoutQuery(
        anchor: HKQueryAnchor?,
        since: Date
    ) async throws -> (added: [HKWorkout], deleted: [HKDeletedObject], anchor: HKQueryAnchor?) {
        try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            let predicate = HKQuery.predicateForSamples(withStart: since, end: nil, options: [])

            let query = HKAnchoredObjectQuery(
                type: HKObjectType.workoutType(),
                predicate: predicate,
                anchor: anchor,
                limit: Self.discoveryLimit
            ) { _, samples, deleted, newAnchor, error in
                guard !hasResumed else { return }
                hasResumed = true

                if let error {
                    continuation.resume(throwing: WorkoutDetailReaderError.queryFailed(error.localizedDescription))
                    return
                }
                continuation.resume(returning: (
                    samples?.compactMap { $0 as? HKWorkout } ?? [],
                    deleted ?? [],
                    newAnchor
                ))
            }
            healthStore.execute(query)
        }
    }

    private func runWorkoutRangeQuery(from start: Date, to end: Date) async throws -> [HKWorkout] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: WorkoutDetailReaderError.queryFailed(error.localizedDescription))
                    return
                }
                continuation.resume(returning: samples?.compactMap { $0 as? HKWorkout } ?? [])
            }
            healthStore.execute(query)
        }
    }

    private func isProtectedDataAvailable() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume(returning: UIApplication.shared.isProtectedDataAvailable)
            }
        }
    }

    // MARK: - Anchor coding

    static func encodeAnchor(_ anchor: HKQueryAnchor) -> String? {
        try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true).base64EncodedString()
    }

    static func decodeAnchor(_ encoded: String) -> HKQueryAnchor? {
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    // MARK: - Telemetry

    /// Fire-and-forget enrichment telemetry on the SDK's existing logs channel.
    ///
    /// Counts, durations, byte totals, and low-cardinality reason codes only. No
    /// identifier, no coordinate, no sample value, and no file name ever reaches here.
    private func sendTelemetry(event: String, fields: [String: Any]) {
        guard let endpoint = sdk.logsEndpoint, let credential = sdk.authCredential else { return }

        var payload: [String: Any] = fields
        payload["eventType"] = event
        payload["timestamp"] = ISO8601DateFormatter().string(from: Date())
        payload["schemaVersion"] = EnrichmentWire.schemaVersion

        let body: [String: Any] = [
            "sdkVersion": OpenWearablesHealthSDK.sdkVersion,
            "provider": EnrichmentWire.provider,
            "events": [payload]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        sdk.applyAuth(to: &request, credential: credential)
        request.httpBody = data
        sdk.foregroundSession.dataTask(with: request) { _, _, _ in }.resume()
    }
}
