import Foundation

// MARK: - State model

/// Where one workout is in the enrichment pipeline.
///
/// `published`/`noop` are reachable **only** from OW's terminal publication receipt.
/// HTTP acceptance of a chunk, or even of the whole upload, never advances a job to a
/// terminal state on its own (brief 7.2 step 10).
enum EnrichmentJobState: String, Codable {
    /// Discovered, nothing read yet.
    case pending
    /// HealthKit is being read and chunk files are being staged.
    case collecting
    /// Manifest and chunks are being transferred.
    case uploading
    /// Everything was accepted and `complete` was called; waiting for the receipt.
    case awaitingReceipt = "awaiting_receipt"
    /// OW confirmed a new published generation.
    case published
    /// OW confirmed the content is identical to the published generation.
    case noop
    /// A conflict or validation failure that retrying cannot fix.
    case failedPermanent = "failed_permanent"
    /// Temporarily not possible (feature flag off, device locked, offline). Retried.
    case deferred
}

/// One workout's enrichment record, keyed in the checkpoint by its logical identity key.
struct EnrichmentJob: Codable, Equatable {
    var identity: EnrichmentIdentityEnvelope
    var state: EnrichmentJobState
    var rootHash: String?
    var familyHashes: [String: String]
    var uploadID: String?
    var generationNumber: Int?
    var attemptCount: Int
    /// Low-cardinality class such as `"http_5xx"` or `"flag_off"`. Never a message that
    /// could carry health data or an identifier.
    var lastErrorClass: String?
    /// Route availability when this workout was last published, so late-route
    /// reconciliation knows which workouts are still worth re-reading.
    var routeAvailabilityAtLastPublish: String?
    /// Kept so reconciliation can bound itself to recent workouts without re-querying.
    var workoutEndDate: Date
    /// Earliest moment a deferred job may be retried.
    var nextAttemptAt: Date?
    var updatedAt: Date

    init(identity: EnrichmentIdentityEnvelope, now: Date = Date()) {
        self.identity = identity
        self.state = .pending
        self.familyHashes = [:]
        self.attemptCount = 0
        self.workoutEndDate = identity.endDate
        self.updatedAt = now
    }

    var isTerminal: Bool {
        state == .published || state == .noop || state == .failedPermanent
    }
}

/// A workout HealthKit reported as deleted. The identity envelope is kept because the
/// workout itself is gone by the time the tombstone is sent.
struct EnrichmentTombstone: Codable, Equatable {
    var identity: EnrichmentIdentityEnvelope
    var deletedAt: Date
    var attemptCount: Int
    var nextAttemptAt: Date?
    var lastErrorClass: String?

    init(identity: EnrichmentIdentityEnvelope, deletedAt: Date) {
        self.identity = identity
        self.deletedAt = deletedAt
        self.attemptCount = 0
    }
}

/// Recent-first historical enrichment progress.
///
/// `windowEnd` walks backwards from "now" toward `earliestBoundary` one bounded window
/// at a time, so an interrupted seed resumes where it stopped instead of restarting.
struct EnrichmentHistoricalCursor: Codable, Equatable {
    var windowEnd: Date
    var earliestBoundary: Date
    var isComplete: Bool

    /// Windows are 7 days so one pass reads a bounded number of workouts.
    static let windowLength: TimeInterval = 7 * 24 * 3600
    /// The initial seed reaches 90 days back.
    static let defaultLookback: TimeInterval = 90 * 24 * 3600

    init(now: Date = Date(), lookback: TimeInterval = EnrichmentHistoricalCursor.defaultLookback) {
        windowEnd = now
        earliestBoundary = now.addingTimeInterval(-lookback)
        isComplete = false
    }

    var windowStart: Date {
        max(earliestBoundary, windowEnd.addingTimeInterval(-Self.windowLength))
    }

    /// Fraction of the requested lookback already walked, for status reporting.
    var progress: Double {
        guard !isComplete else { return 1 }
        let total = windowEnd.timeIntervalSince(earliestBoundary)
        guard total > 0 else { return 1 }
        let remaining = max(0, windowStart.timeIntervalSince(earliestBoundary))
        return max(0, min(1, 1 - (remaining / max(total, 1))))
    }

    mutating func advance() {
        let next = windowStart
        if next <= earliestBoundary { isComplete = true }
        windowEnd = next
    }
}

/// Everything the enrichment pipeline must survive a process death with.
struct EnrichmentCheckpointState: Codable, Equatable {

    /// Bump when the persisted shape changes incompatibly.
    static let currentVersion = 1

    var version: Int
    var userKey: String
    var isEnabled: Bool
    var heartRateOnly: Bool
    var routeSharingEnabled: Bool
    var hasRequestedAuthorization: Bool
    /// Base64 `HKQueryAnchor` for workout discovery, owned by enrichment alone.
    ///
    /// This is deliberately **not** one of the core sync anchors: `resetAnchors()` must
    /// never be the way a device discovers newly supported detail (brief 7.4), so the
    /// core reset path leaves this untouched.
    var discoveryAnchor: String?
    var jobs: [String: EnrichmentJob]
    var tombstones: [String: EnrichmentTombstone]
    var historicalCursor: EnrichmentHistoricalCursor?
    var updatedAt: Date

    init(userKey: String, now: Date = Date()) {
        self.version = Self.currentVersion
        self.userKey = userKey
        self.isEnabled = false
        self.heartRateOnly = false
        self.routeSharingEnabled = false
        self.hasRequestedAuthorization = false
        self.jobs = [:]
        self.tombstones = [:]
        self.updatedAt = now
    }

    private enum CodingKeys: String, CodingKey {
        case version, userKey, isEnabled, heartRateOnly, routeSharingEnabled, hasRequestedAuthorization,
             discoveryAnchor, jobs, tombstones, historicalCursor, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        userKey = try c.decode(String.self, forKey: .userKey)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        heartRateOnly = try c.decodeIfPresent(Bool.self, forKey: .heartRateOnly) ?? false
        routeSharingEnabled = try c.decodeIfPresent(Bool.self, forKey: .routeSharingEnabled) ?? false
        hasRequestedAuthorization = try c.decode(Bool.self, forKey: .hasRequestedAuthorization)
        discoveryAnchor = try c.decodeIfPresent(String.self, forKey: .discoveryAnchor)
        jobs = try c.decode([String: EnrichmentJob].self, forKey: .jobs)
        tombstones = try c.decode([String: EnrichmentTombstone].self, forKey: .tombstones)
        historicalCursor = try c.decodeIfPresent(EnrichmentHistoricalCursor.self, forKey: .historicalCursor)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    /// Counts by state, for the public status dictionary. No identifiers.
    var jobCountsByState: [String: Int] {
        var counts: [String: Int] = [:]
        for job in jobs.values { counts[job.state.rawValue, default: 0] += 1 }
        return counts
    }

    /// Published workouts whose route has still not arrived — the reconciliation queue.
    var routePendingCount: Int {
        jobs.values.filter {
            ($0.state == .published || $0.state == .noop)
                && ($0.routeAvailabilityAtLastPublish == WorkoutDetailAvailability.pendingEnrichment.rawValue
                    || $0.routeAvailabilityAtLastPublish == WorkoutDetailAvailability.notAvailableOrNotAuthorized.rawValue)
        }.count
    }

    /// Distinct low-cardinality error classes currently recorded, for status/telemetry.
    var errorClasses: [String] {
        Array(Set(jobs.values.compactMap { $0.lastErrorClass })).sorted()
    }
}

// MARK: - Store

/// Durable, per-OW-user checkpoint file.
///
/// One file holds the whole state and carries the `userKey` inside, mirroring
/// `Session.swift`. A state belonging to a different user is never merged or migrated:
/// it is discarded, because an enrichment queue is per-account and there is no
/// cross-account recovery path.
final class EnrichmentCheckpointStore {

    private let directory: URL
    private let lock = NSLock()

    init(directory: URL) {
        self.directory = directory
    }

    var stateFileURL: URL { directory.appendingPathComponent("state.json") }
    var temporaryFileURL: URL { directory.appendingPathComponent("state.json.tmp") }

    // MARK: Load / save

    /// Current state for `userKey`, or a fresh one when the file is absent, unreadable,
    /// written by an older layout, or owned by another user.
    func load(userKey: String) -> EnrichmentCheckpointState {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked(userKey: userKey)
    }

    private func loadUnlocked(userKey: String) -> EnrichmentCheckpointState {
        guard let data = try? Data(contentsOf: stateFileURL),
              let state = try? JSONDecoder().decode(EnrichmentCheckpointState.self, from: data),
              state.version == EnrichmentCheckpointState.currentVersion,
              state.userKey == userKey else {
            return EnrichmentCheckpointState(userKey: userKey)
        }
        return state
    }

    /// Reads, mutates, and persists in one atomic step.
    ///
    /// This single-writer shape is what lets the coordinator commit a newly advanced
    /// discovery anchor and the jobs that anchor produced in the *same* write. Persisting
    /// them separately would let a crash in between advance the anchor past work that was
    /// never queued, which loses those workouts permanently.
    @discardableResult
    func mutate<T>(userKey: String, _ body: (inout EnrichmentCheckpointState) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }

        var state = loadUnlocked(userKey: userKey)
        let result = body(&state)
        state.updatedAt = Date()
        state.version = EnrichmentCheckpointState.currentVersion
        state.userKey = userKey
        persist(state)
        return result
    }

    private func persist(_ state: EnrichmentCheckpointState) {
        ensureDirectory()
        guard let data = try? JSONEncoder().encode(state) else { return }

        // Write beside the target, then swap it in. A process death before the swap
        // leaves the previous state file intact and readable, which is the only
        // acceptable failure mode for a queue that owns unpublished work.
        do {
            try data.write(to: temporaryFileURL, options: .atomic)
            EnrichmentFileProtection.apply(to: temporaryFileURL)

            if FileManager.default.fileExists(atPath: stateFileURL.path) {
                _ = try FileManager.default.replaceItemAt(stateFileURL, withItemAt: temporaryFileURL)
            } else {
                try FileManager.default.moveItem(at: temporaryFileURL, to: stateFileURL)
            }
            EnrichmentFileProtection.apply(to: stateFileURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryFileURL)
        }
    }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        EnrichmentFileProtection.apply(to: directory)
    }

    // MARK: Cleanup

    /// Removes the whole checkpoint. Called on sign-out and on sign-in as a different
    /// user — an enrichment queue never crosses accounts.
    func deleteAll() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: stateFileURL)
        try? FileManager.default.removeItem(at: temporaryFileURL)
    }
}

// MARK: - File protection

/// Applies the two protections every enrichment file needs.
///
/// Enrichment files contain precise location and physiological data, so they must not
/// reach iCloud or a device backup, and they must be encrypted at rest. Protection is
/// `completeUntilFirstUserAuthentication` rather than `complete` because background
/// uploads and observer wakes run while the screen is locked; the data is still
/// unreadable until the device has been unlocked once after boot.
enum EnrichmentFileProtection {

    static let protectionClass = FileProtectionType.completeUntilFirstUserAuthentication

    static func apply(to url: URL) {
        var target = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? target.setResourceValues(resourceValues)

        try? FileManager.default.setAttributes(
            [.protectionKey: protectionClass],
            ofItemAtPath: url.path
        )
    }

    /// Reads back what was actually applied, so a test can assert it rather than trust it.
    static func isProtected(_ url: URL) -> Bool {
        let excluded = (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup ?? false
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let protection = attributes?[.protectionKey] as? FileProtectionType
        // The simulator does not implement data protection, so the attribute is absent
        // there; backup exclusion is honoured on both and is asserted unconditionally.
        return excluded && (protection == nil || protection == protectionClass)
    }
}
