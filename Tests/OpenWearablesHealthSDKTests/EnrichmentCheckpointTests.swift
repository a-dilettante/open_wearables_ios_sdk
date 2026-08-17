import XCTest
@testable import OpenWearablesHealthSDK

/// Durability of the enrichment checkpoint: round-trip, atomic replacement, the
/// anchor/jobs commit boundary, per-user isolation, and file protection.
///
/// Every test writes into its own temporary directory, never the real Application
/// Support location.
final class EnrichmentCheckpointTests: XCTestCase {

    private var directory: URL!
    private var store: EnrichmentCheckpointStore!

    private let userA = "user.test-a"
    private let userB = "user.test-b"

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("enrichment-checkpoint-\(UUID().uuidString)", isDirectory: true)
        store = EnrichmentCheckpointStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        store = nil
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeJob(syncIdentifier: String = "acme-sync-9f3c1d77") -> EnrichmentJob {
        var identity = WorkoutDetailTestFixtures.identity()
        identity.syncIdentifier = syncIdentifier
        return EnrichmentJob(identity: EnrichmentIdentityEnvelope(identity))
    }

    // MARK: - Round trip

    func testRoundTripPreservesEveryField() {
        var job = makeJob()
        job.state = .awaitingReceipt
        job.rootHash = WorkoutDetailHashing.sha256Hex("root")
        job.familyHashes = ["route": WorkoutDetailHashing.sha256Hex("route")]
        job.uploadID = "ba2705987c50cf86a7cf7e7a1a06d255"
        job.generationNumber = 7
        job.attemptCount = 2
        job.lastErrorClass = "http_5xx"
        job.routeAvailabilityAtLastPublish = WorkoutDetailAvailability.pendingEnrichment.rawValue
        job.nextAttemptAt = Date(timeIntervalSince1970: 1_800_000_000)

        let key = job.identity.identityKey
        store.mutate(userKey: userA) { state in
            state.isEnabled = true
            state.hasRequestedAuthorization = true
            state.discoveryAnchor = "YW5jaG9y"
            state.jobs[key] = job
            state.historicalCursor = EnrichmentHistoricalCursor(now: Date(timeIntervalSince1970: 1_800_000_000))
        }

        // A fresh store proves the state came off disk, not out of memory.
        let reloaded = EnrichmentCheckpointStore(directory: directory).load(userKey: userA)
        XCTAssertTrue(reloaded.isEnabled)
        XCTAssertTrue(reloaded.hasRequestedAuthorization)
        XCTAssertEqual(reloaded.discoveryAnchor, "YW5jaG9y")
        XCTAssertEqual(reloaded.jobs[key], job, "every job field must survive a round trip exactly")
        XCTAssertEqual(reloaded.historicalCursor?.windowEnd, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testTombstoneRoundTripKeepsIdentityForADeletedWorkout() {
        let envelope = EnrichmentIdentityEnvelope(WorkoutDetailTestFixtures.identity())
        let key = envelope.identityKey
        let tombstone = EnrichmentTombstone(identity: envelope, deletedAt: Date(timeIntervalSince1970: 1_700_000_000))

        store.mutate(userKey: userA) { $0.tombstones[key] = tombstone }

        let reloaded = store.load(userKey: userA).tombstones[key]
        XCTAssertEqual(reloaded, tombstone)
        // The envelope is what lets a tombstone be sent after HealthKit forgot the workout.
        XCTAssertEqual(reloaded?.identity.healthKitWorkoutUUID, WorkoutDetailTestFixtures.workoutUUID)
    }

    // MARK: - Atomic write

    /// A crash between writing the temporary file and swapping it in must leave the
    /// previous state readable. Losing the checkpoint would orphan unpublished work.
    func testInterruptedWriteLeavesPreviousStateReadable() throws {
        let key = makeJob().identity.identityKey
        store.mutate(userKey: userA) { state in
            state.isEnabled = true
            state.jobs[key] = self.makeJob()
        }
        let before = store.load(userKey: userA)
        XCTAssertEqual(before.jobs.count, 1)

        // Simulate a process death after the temp file was written but before the swap.
        try Data("{\"partial\":true".utf8).write(to: store.temporaryFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.temporaryFileURL.path))

        let after = EnrichmentCheckpointStore(directory: directory).load(userKey: userA)
        XCTAssertTrue(after.isEnabled)
        XCTAssertEqual(after.jobs.count, 1)
        XCTAssertEqual(after.jobs[key], before.jobs[key])
    }

    func testCorruptStateFileFallsBackToEmptyRatherThanCrashing() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: store.stateFileURL)

        let state = store.load(userKey: userA)
        XCTAssertTrue(state.jobs.isEmpty)
        XCTAssertFalse(state.isEnabled)
        XCTAssertNil(state.discoveryAnchor)
    }

    func testStateFromAnOlderLayoutIsDiscarded() throws {
        store.mutate(userKey: userA) { $0.isEnabled = true }

        var raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try Data(contentsOf: store.stateFileURL)) as? [String: Any]
        )
        raw["version"] = 999
        try JSONSerialization.data(withJSONObject: raw).write(to: store.stateFileURL)

        XCTAssertFalse(store.load(userKey: userA).isEnabled, "an unknown layout must not be half-read")
    }

    // MARK: - Anchor / jobs atomicity

    /// The discovery anchor and the jobs it produced must land in the same write. If the
    /// anchor could advance separately, a crash in between would move it past workouts
    /// HealthKit will never report again.
    func testAnchorAndJobsCommitInOneWrite() throws {
        let job = makeJob()
        let key = job.identity.identityKey

        store.mutate(userKey: userA) { state in
            state.jobs[key] = job
            state.discoveryAnchor = "YWR2YW5jZWQ="
        }

        // One decode of one file must show both halves; there is no intermediate file
        // version containing the anchor without the job.
        let decoded = try JSONDecoder().decode(
            EnrichmentCheckpointState.self,
            from: try Data(contentsOf: store.stateFileURL)
        )
        XCTAssertEqual(decoded.discoveryAnchor, "YWR2YW5jZWQ=")
        XCTAssertNotNil(decoded.jobs[key])
    }

    /// The converse: work can be persisted without advancing the anchor. That is the
    /// safe direction — the same workouts are simply rediscovered.
    func testJobsCanPersistWithoutAdvancingAnchor() {
        store.mutate(userKey: userA) { $0.jobs[self.makeJob().identity.identityKey] = self.makeJob() }

        let state = store.load(userKey: userA)
        XCTAssertEqual(state.jobs.count, 1)
        XCTAssertNil(state.discoveryAnchor, "a failed query must leave the anchor untouched")
    }

    // MARK: - Per-user isolation

    func testStateForADifferentUserIsNeverReturned() {
        store.mutate(userKey: userA) { state in
            state.isEnabled = true
            state.discoveryAnchor = "YW5jaG9y"
            state.jobs[self.makeJob().identity.identityKey] = self.makeJob()
        }

        let other = store.load(userKey: userB)
        XCTAssertTrue(other.jobs.isEmpty, "an enrichment queue must never cross accounts")
        XCTAssertNil(other.discoveryAnchor)
        XCTAssertFalse(other.isEnabled)
    }

    func testDeleteAllRemovesStateAndTemporaryFile() throws {
        store.mutate(userKey: userA) { $0.isEnabled = true }
        try Data("{}".utf8).write(to: store.temporaryFileURL)

        store.deleteAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.stateFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.temporaryFileURL.path))
        XCTAssertTrue(store.load(userKey: userA).jobs.isEmpty)
    }

    // MARK: - File protection

    /// The checkpoint holds workout identities, so it must not reach iCloud or a device
    /// backup. The simulator does not implement data protection, so the protection class
    /// is only asserted when the platform reports one.
    func testStateFileIsExcludedFromBackupAndProtected() throws {
        store.mutate(userKey: userA) { $0.isEnabled = true }

        let excluded = try store.stateFileURL
            .resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excluded, true)
        XCTAssertTrue(EnrichmentFileProtection.isProtected(store.stateFileURL))

        if let applied = try FileManager.default
            .attributesOfItem(atPath: store.stateFileURL.path)[.protectionKey] as? FileProtectionType {
            XCTAssertEqual(applied, .completeUntilFirstUserAuthentication)
        }
    }

    // MARK: - Historical cursor

    func testHistoricalCursorWalksBackwardsAndCompletes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var cursor = EnrichmentHistoricalCursor(now: now, lookback: 21 * 24 * 3600)

        XCTAssertFalse(cursor.isComplete)
        XCTAssertEqual(cursor.windowEnd, now)
        XCTAssertEqual(cursor.windowStart, now.addingTimeInterval(-7 * 24 * 3600))

        cursor.advance()
        XCTAssertEqual(cursor.windowEnd, now.addingTimeInterval(-7 * 24 * 3600))
        XCTAssertFalse(cursor.isComplete)

        cursor.advance()
        cursor.advance()
        XCTAssertTrue(cursor.isComplete, "the cursor must terminate at the requested boundary")
        XCTAssertEqual(cursor.progress, 1)
    }

    func testCursorNeverWalksPastTheRequestedBoundary() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var cursor = EnrichmentHistoricalCursor(now: now, lookback: 3 * 24 * 3600)

        // The first window is shorter than the window length; it must clamp, not overrun.
        XCTAssertEqual(cursor.windowStart, cursor.earliestBoundary)
        cursor.advance()
        XCTAssertTrue(cursor.isComplete)
        XCTAssertGreaterThanOrEqual(cursor.windowEnd, cursor.earliestBoundary)
    }

    // MARK: - Status projection

    func testStatusProjectionCountsWithoutExposingIdentifiers() {
        var published = makeJob(syncIdentifier: "sync-published")
        published.state = .published
        published.routeAvailabilityAtLastPublish = WorkoutDetailAvailability.pendingEnrichment.rawValue

        var deferred = makeJob(syncIdentifier: "sync-deferred")
        deferred.state = .deferred
        deferred.lastErrorClass = "flag_off"

        var complete = makeJob(syncIdentifier: "sync-complete")
        complete.state = .published
        complete.routeAvailabilityAtLastPublish = WorkoutDetailAvailability.available.rawValue

        store.mutate(userKey: userA) { state in
            for job in [published, deferred, complete] {
                state.jobs[job.identity.identityKey] = job
            }
        }

        let state = store.load(userKey: userA)
        XCTAssertEqual(state.jobCountsByState["published"], 2)
        XCTAssertEqual(state.jobCountsByState["deferred"], 1)
        XCTAssertEqual(state.routePendingCount, 1, "only the still-pending route counts")
        XCTAssertEqual(state.errorClasses, ["flag_off"])
    }
}
