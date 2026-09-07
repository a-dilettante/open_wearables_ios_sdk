import Foundation
import HealthKit

/// Public entry points for workout-detail enrichment, plus the small amount of glue the
/// core engine calls into.
///
/// Enrichment is a pipeline beside the core sync engine, not part of it: it has its own
/// checkpoint, its own outbox, its own anchor, and its own triggers. Everything the core
/// engine does for it is in this file and in a handful of one-line hooks.
extension OpenWearablesHealthSDK {

    // MARK: - Storage locations

    private static func applicationSupportDirectory() -> URL {
        let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base ?? FileManager.default.temporaryDirectory
    }

    static func enrichmentStateDirectory() -> URL {
        applicationSupportDirectory().appendingPathComponent("health_enrichment", isDirectory: true)
    }

    static func enrichmentOutboxDirectory() -> URL {
        applicationSupportDirectory().appendingPathComponent("health_enrichment_outbox", isDirectory: true)
    }

    // MARK: - Public API

    /// Turns workout-detail enrichment on or off for the signed-in user.
    ///
    /// Enabling requests nothing by itself — call `requestWorkoutDetailAuthorization()`
    /// when the app is ready to show the HealthKit sheet. Disabling stops all passes and
    /// deletes the staged upload files, which contain precise location and physiological
    /// data and have no purpose once enrichment is off. The checkpoint itself is kept, so
    /// re-enabling resumes instead of re-uploading everything already published.
    public func setWorkoutDetailEnrichmentEnabled(_ enabled: Bool) {
        enrichmentCheckpoint.mutate(userKey: userKey()) { $0.isEnabled = enabled }
        if !enabled {
            cancelEnrichmentTransfers()
            enrichmentOutbox.removeAll()
        }
        logMessage("Workout-detail enrichment \(enabled ? "enabled" : "disabled")")
    }

    /// Enables the first, HR-only owned stream slice. This keeps the public upgrade
    /// explicit while allowing hosts to ship exact workout attribution before route
    /// and recorder-event collection is enabled.
    public func setWorkoutHeartRateEnrichmentEnabled(_ enabled: Bool) {
        enrichmentCheckpoint.mutate(userKey: userKey()) {
            $0.isEnabled = enabled
            $0.heartRateOnly = enabled && !$0.routeSharingEnabled
            $0.hasRequestedAuthorization = enabled
        }
        if !enabled {
            cancelEnrichmentTransfers()
            enrichmentOutbox.removeAll()
        }
        logMessage("Workout HR enrichment \(enabled ? "enabled" : "disabled")")
    }

    /// Requests HealthKit read access for workout, workout route, and heart rate.
    ///
    /// This deliberately does **not** go through `requestAuthorization(types:completion:)`,
    /// which replaces the SDK's persisted tracked-type set: routing an enrichment request
    /// through it would silently reduce a host app's core sync to these three types.
    ///
    /// Returning does not mean access was granted. Apple makes read authorization opaque
    /// on purpose, so a denied read is indistinguishable from absent data and this SDK
    /// never claims otherwise.
    public func requestWorkoutDetailAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw WorkoutDetailReaderError.healthDataUnavailable
        }
        await enrichmentCoordinator.requestAuthorization()
    }

    /// Explicit route opt-in. A completed permission sheet does not prove read access.
    /// Revisit recent terminal jobs without resetting the core HealthKit anchors.
    public func requestWorkoutRouteSharing() async -> Bool {
        let owner = userKey()
        guard await enrichmentCoordinator.requestAuthorization(), userKey() == owner else { return false }
        enrichmentCheckpoint.mutate(userKey: owner) { state in
            state.routeSharingEnabled = true
            state.heartRateOnly = false
            state.isEnabled = true
            let now = Date()
            for (key, job) in state.jobs {
                guard job.state == .published || job.state == .noop,
                      job.workoutEndDate <= now,
                      now.timeIntervalSince(job.workoutEndDate) < 7 * 24 * 3600 else { continue }
                var updated = job
                updated.state = .pending
                updated.nextAttemptAt = nil
                updated.updatedAt = now
                state.jobs[key] = updated
            }
        }
        startWorkoutDetailEnrichmentPass()
        return true
    }

    /// Redaction-safe enrichment status: counts, error classes, and progress only.
    ///
    /// Contains no workout identifier, no coordinate, no sample value, and no file name,
    /// so it is safe to log, display, or forward to JavaScript.
    public func getWorkoutDetailEnrichmentStatus() -> [String: Any] {
        let state = enrichmentCheckpoint.load(userKey: userKey())
        let stagedUploads = (try? FileManager.default.contentsOfDirectory(
            atPath: Self.enrichmentOutboxDirectory().path
        ).count) ?? 0

        return [
            "enabled": state.isEnabled,
            "routeSharingEnabled": state.routeSharingEnabled,
            "authorizationRequested": state.hasRequestedAuthorization,
            "countsByState": state.jobCountsByState,
            "routePendingCount": state.routePendingCount,
            "pendingTombstoneCount": state.tombstones.count,
            "errorClasses": state.errorClasses,
            "historicalProgressPercent": state.historicalCursor.map { Int($0.progress * 100) } ?? 0,
            "historicalComplete": state.historicalCursor?.isComplete ?? false,
            "stagedUploads": stagedUploads
        ]
    }

    /// Runs one enrichment pass now, if one is not already running and the core sync is
    /// idle. Automatic passes also run after each sync round, on foreground, and on
    /// workout observer wakes.
    public func startWorkoutDetailEnrichmentPass() {
        enrichmentCoordinator.runPass(reason: "manual")
    }

    // MARK: - Engine hooks

    /// Called when the core sync finishes a round. Enrichment never runs concurrently
    /// with core sync, so this is the natural moment to pick up newly synced workouts.
    internal func scheduleEnrichmentPassAfterSync() {
        guard enrichmentCheckpoint != nil,
              enrichmentCheckpoint.load(userKey: userKey()).isEnabled else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.enrichmentCoordinator.runPass(reason: "post_sync", debounce: 60)
        }
    }

    /// Foreground and observer-wake trigger, debounced so a burst of wakes produces one
    /// pass. Late routes are found here, since no route observer is registered.
    internal func triggerEnrichmentPass(reason: String, debounce: TimeInterval) {
        guard enrichmentCheckpoint != nil,
              enrichmentCheckpoint.load(userKey: userKey()).isEnabled else { return }
        enrichmentCoordinator.runPass(reason: reason, debounce: debounce)
    }

    /// Deletes the enrichment checkpoint and every staged file.
    ///
    /// The enrichment queue is per-OW-user with no cross-account recovery path, so this
    /// runs on sign-out and when signing in as a different user. It is deliberately not
    /// called by `resetAnchors()`: the detail checkpoint is independent of the core
    /// anchors, and resetting global anchors must never be how a device rediscovers
    /// detail (brief 7.4).
    internal func clearEnrichmentState() {
        cancelEnrichmentTransfers()
        enrichmentCheckpoint.deleteAll()
        enrichmentOutbox.removeAll()
        logMessage("Cleared workout-detail enrichment state")
    }

    /// Cancels in-flight enrichment chunk transfers without disturbing core uploads.
    internal func cancelEnrichmentTransfers() {
        session.getAllTasks { tasks in
            for task in tasks where task.taskDescription?.hasPrefix("\(EnrichmentUploader.taskPrefix)|") == true {
                task.cancel()
            }
        }
    }
}
