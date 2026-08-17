import XCTest
@testable import OpenWearablesHealthSDK

/// The coordinator's job-scheduling rules.
///
/// Only the pure transitions are exercised here: no HealthKit, no network, no files.
final class EnrichmentCoordinatorTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func pendingJob() -> EnrichmentJob {
        EnrichmentJob(identity: EnrichmentIdentityEnvelope(WorkoutDetailTestFixtures.identity()), now: now)
    }

    // MARK: - Collection-phase deferral

    /// A failure while reading HealthKit must leave the job collectable.
    ///
    /// There is no upload id yet at that point, so parking the job in `deferred` would
    /// strand it: collection only picks up `pending`, and the resume loop only nudges jobs
    /// that already have an upload id. The job would then sit in the checkpoint until it
    /// was pruned months later, and that workout would never be enriched.
    func testCollectionFailureReturnsTheJobToPendingWithBackoff() {
        let deferred = EnrichmentCoordinator.deferCollection(
            pendingJob(),
            errorClass: "workout_unavailable",
            now: now
        )

        XCTAssertEqual(deferred.state, .pending, "a collection failure must stay collectable")
        XCTAssertNil(deferred.uploadID, "nothing was staged, so no upload id may be claimed")
        XCTAssertEqual(deferred.attemptCount, 1)
        XCTAssertEqual(deferred.lastErrorClass, "workout_unavailable")
        XCTAssertEqual(deferred.nextAttemptAt, now.addingTimeInterval(EnrichmentUploader.backoff(attempt: 1)))
    }

    /// The back-off is honoured rather than becoming a hot loop: the job is skipped until
    /// its next attempt is due, and collected from then on.
    func testDeferredJobIsSkippedUntilDueAndThenCollected() throws {
        let deferred = EnrichmentCoordinator.deferCollection(pendingJob(), errorClass: "staging_failed", now: now)
        let due = try XCTUnwrap(deferred.nextAttemptAt)

        XCTAssertFalse(EnrichmentCoordinator.isDueForCollection(deferred, now: now))
        XCTAssertFalse(EnrichmentCoordinator.isDueForCollection(deferred, now: due.addingTimeInterval(-1)))
        XCTAssertTrue(EnrichmentCoordinator.isDueForCollection(deferred, now: due))
        XCTAssertTrue(EnrichmentCoordinator.isDueForCollection(deferred, now: due.addingTimeInterval(3600)))
    }

    /// Repeated collection failures back off further instead of retrying at a fixed rate.
    func testRepeatedCollectionFailuresBackOffFurther() {
        let first = EnrichmentCoordinator.deferCollection(pendingJob(), errorClass: "workout_unavailable", now: now)
        let second = EnrichmentCoordinator.deferCollection(first, errorClass: "workout_unavailable", now: now)

        XCTAssertEqual(second.attemptCount, 2)
        XCTAssertGreaterThan(second.nextAttemptAt ?? .distantPast, first.nextAttemptAt ?? .distantFuture)
    }

    // MARK: - Collection eligibility

    /// A freshly discovered job is collected immediately; anything in flight or already
    /// finished is not re-read.
    func testOnlyPendingJobsWithNoOutstandingBackoffAreCollected() {
        var job = pendingJob()
        XCTAssertTrue(EnrichmentCoordinator.isDueForCollection(job, now: now))

        for state in [
            EnrichmentJobState.collecting, .uploading, .awaitingReceipt,
            .published, .noop, .failedPermanent, .deferred
        ] {
            job.state = state
            XCTAssertFalse(
                EnrichmentCoordinator.isDueForCollection(job, now: now),
                "\(state.rawValue) must not be collected"
            )
        }
    }
}
