import XCTest
@testable import OpenWearablesHealthSDK

/// The upload state machine, response classification, backoff, and URL construction.
///
/// Everything under test is a pure function, so no network, no HealthKit, and no files
/// are involved.
final class EnrichmentUploaderTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeJob() -> EnrichmentJob {
        var job = EnrichmentJob(identity: EnrichmentIdentityEnvelope(WorkoutDetailTestFixtures.identity()))
        job.uploadID = "ba2705987c50cf86a7cf7e7a1a06d255"
        job.rootHash = WorkoutDetailHashing.sha256Hex("root")
        return job
    }

    // MARK: - Classification

    func testSuccessfulStatusesAreAccepted() {
        for status in [200, 201, 204, 299] {
            XCTAssertEqual(EnrichmentUploader.classify(statusCode: status, phase: .manifest), .accepted)
        }
    }

    /// Every route answers 404 while the server feature flag is off. That is a deferral,
    /// never a failure and never a dead letter.
    func testFlagOffIsDeferralNotFailure() {
        for phase in [EnrichmentUploadPhase.manifest, .chunk, .complete, .receipt, .tombstone] {
            XCTAssertEqual(
                EnrichmentUploader.classify(statusCode: 404, phase: phase),
                .featureUnavailable,
                "404 on \(phase.rawValue) must defer"
            )
        }
        XCTAssertEqual(EnrichmentUploadOutcome.featureUnavailable.errorClass, "flag_off")
    }

    /// A 409 means different things in different phases: the manifest is unrecoverable,
    /// a chunk means the content moved underneath this upload.
    func testConflictMeaningDependsOnPhase() {
        XCTAssertEqual(EnrichmentUploader.classify(statusCode: 409, phase: .manifest), .manifestConflict)
        XCTAssertEqual(EnrichmentUploader.classify(statusCode: 409, phase: .chunk), .chunkConflict)
    }

    func testServerLimitsAndTransientsAreClassified() {
        XCTAssertEqual(EnrichmentUploader.classify(statusCode: 413, phase: .chunk), .permanent("payload_too_large"))
        XCTAssertEqual(EnrichmentUploader.classify(statusCode: 422, phase: .chunk), .permanent("validation_failed"))
        XCTAssertEqual(EnrichmentUploader.classify(statusCode: 405, phase: .chunk), .permanent("http_4xx"))
        XCTAssertEqual(EnrichmentUploader.classify(statusCode: 401, phase: .manifest), .unauthorized)
        XCTAssertEqual(EnrichmentUploader.classify(statusCode: 403, phase: .manifest), .unauthorized)
        XCTAssertEqual(EnrichmentUploader.classify(statusCode: 500, phase: .complete), .transient("http_5xx"))
        XCTAssertEqual(EnrichmentUploader.classify(statusCode: 503, phase: .complete), .transient("http_5xx"))
        XCTAssertEqual(EnrichmentUploader.classify(statusCode: 0, phase: .complete), .transient("no_response"))
    }

    /// 400, 413 and 422 are three ways of saying "these exact bytes will never be
    /// accepted", and all three must be terminal.
    ///
    /// 400 is the one that is easy to get wrong. OW converts FastAPI's
    /// `RequestValidationError` into a 400 rather than the framework's own 422, so every
    /// schema rejection — an unknown manifest field, an availability that cannot carry
    /// chunks, overlapping laps — arrives as 400. Retrying it would replay the same
    /// rejection until the outbox expired.
    func testSchemaRejectionsAreTerminalInEveryPhase() {
        for phase in [EnrichmentUploadPhase.manifest, .chunk, .complete, .receipt, .tombstone] {
            for status in [400, 413, 422] {
                let outcome = EnrichmentUploader.classify(statusCode: status, phase: phase)
                guard case .permanent = outcome else {
                    XCTFail("HTTP \(status) in \(phase.rawValue) must be terminal, got \(outcome)")
                    continue
                }

                // Terminal means the job stops, not that it waits longer.
                let job = EnrichmentUploader.apply(outcome: outcome, phase: phase, to: makeJob(), now: now)
                XCTAssertEqual(job.state, .failedPermanent, "HTTP \(status) in \(phase.rawValue)")
                XCTAssertNil(job.nextAttemptAt, "a terminal rejection must not schedule a retry")
            }
        }

        XCTAssertEqual(EnrichmentUploader.classify(statusCode: 400, phase: .manifest).errorClass, "schema_rejected")
    }

    // MARK: - Backoff

    func testBackoffGrowsAndIsCapped() {
        XCTAssertEqual(EnrichmentUploader.backoff(attempt: 0), 30)
        XCTAssertEqual(EnrichmentUploader.backoff(attempt: 1), 60)
        XCTAssertEqual(EnrichmentUploader.backoff(attempt: 2), 120)
        XCTAssertEqual(EnrichmentUploader.backoff(attempt: 30), 6 * 3600, "backoff must be capped")
        XCTAssertEqual(EnrichmentUploader.backoff(attempt: -5), 30, "a negative attempt must not go backwards")
    }

    // MARK: - Transitions

    /// HTTP acceptance of a manifest or a chunk is not publication. Only a receipt can
    /// produce a terminal published state (brief 7.2 step 10).
    func testAcceptedBytesNeverPublish() {
        for phase in [EnrichmentUploadPhase.manifest, .chunk] {
            let updated = EnrichmentUploader.apply(outcome: .accepted, phase: phase, to: makeJob(), now: now)
            XCTAssertEqual(updated.state, .uploading)
            XCTAssertNotEqual(updated.state, .published)
            XCTAssertNil(updated.generationNumber)
            XCTAssertNil(updated.lastErrorClass)
        }
    }

    func testAcceptedCompleteAwaitsTheReceipt() {
        let updated = EnrichmentUploader.apply(outcome: .accepted, phase: .complete, to: makeJob(), now: now)
        XCTAssertEqual(updated.state, .awaitingReceipt)
        XCTAssertEqual(updated.attemptCount, 0)
        XCTAssertNil(updated.nextAttemptAt)
    }

    /// The flag being off must keep every durable identifier so the same upload resumes
    /// when the flag turns on.
    func testFeatureUnavailableDefersAndKeepsDurableState() {
        let job = makeJob()
        let updated = EnrichmentUploader.apply(outcome: .featureUnavailable, phase: .manifest, to: job, now: now)

        XCTAssertEqual(updated.state, .deferred)
        XCTAssertEqual(updated.lastErrorClass, "flag_off")
        XCTAssertEqual(updated.attemptCount, 1)
        XCTAssertEqual(updated.nextAttemptAt, now.addingTimeInterval(60))
        XCTAssertEqual(updated.uploadID, job.uploadID, "a deferral must not discard the staged upload")
        XCTAssertEqual(updated.rootHash, job.rootHash)
        XCTAssertNotEqual(updated.state, .failedPermanent, "a flag-off is never a dead letter")
    }

    func testRepeatedDeferralsBackOffFurther() {
        var job = makeJob()
        for expected in [60.0, 120.0, 240.0, 480.0] {
            job = EnrichmentUploader.apply(outcome: .transient("http_5xx"), phase: .chunk, to: job, now: now)
            XCTAssertEqual(job.nextAttemptAt, now.addingTimeInterval(expected))
            XCTAssertEqual(job.state, .deferred)
        }
    }

    /// A manifest conflict means a different manifest already claimed this upload id;
    /// retrying cannot resolve it.
    func testManifestConflictIsPermanent() {
        let updated = EnrichmentUploader.apply(outcome: .manifestConflict, phase: .manifest, to: makeJob(), now: now)

        XCTAssertEqual(updated.state, .failedPermanent)
        XCTAssertEqual(updated.lastErrorClass, "manifest_conflict")
        XCTAssertNil(updated.nextAttemptAt)
        XCTAssertTrue(updated.isTerminal)
    }

    /// A chunk conflict means the content changed mid-flight. The upload is re-derived
    /// from a fresh read, which produces a new root hash and a new upload id.
    func testChunkConflictReDerivesTheUpload() {
        let updated = EnrichmentUploader.apply(outcome: .chunkConflict, phase: .chunk, to: makeJob(), now: now)

        XCTAssertEqual(updated.state, .pending)
        XCTAssertNil(updated.uploadID, "the stale upload id must not be reused")
        XCTAssertNil(updated.rootHash)
        XCTAssertEqual(updated.lastErrorClass, "content_changed")
        XCTAssertEqual(updated.nextAttemptAt, now)
    }

    func testUnauthorizedStaysRetryable() {
        let updated = EnrichmentUploader.apply(outcome: .unauthorized, phase: .manifest, to: makeJob(), now: now)
        XCTAssertEqual(updated.state, .deferred)
        XCTAssertEqual(updated.lastErrorClass, "unauthorized")
        XCTAssertFalse(updated.isTerminal, "token refresh owns recovery; the job is not failed")
    }

    func testPermanentServerRejectionIsTerminal() {
        let updated = EnrichmentUploader.apply(
            outcome: .permanent("validation_failed"), phase: .chunk, to: makeJob(), now: now
        )
        XCTAssertEqual(updated.state, .failedPermanent)
        XCTAssertEqual(updated.lastErrorClass, "validation_failed")
    }

    // MARK: - Receipt

    func testPublishedReceiptRecordsGenerationAndRouteAvailability() {
        let updated = EnrichmentUploader.applyReceipt(
            state: "published",
            generationNumber: 3,
            failureReason: nil,
            routeAvailability: .available,
            to: makeJob(),
            now: now
        )

        XCTAssertEqual(updated.state, .published)
        XCTAssertEqual(updated.generationNumber, 3)
        XCTAssertEqual(updated.routeAvailabilityAtLastPublish, "available")
        XCTAssertNil(updated.lastErrorClass)
        XCTAssertNil(updated.nextAttemptAt)
        XCTAssertTrue(updated.isTerminal)
    }

    /// `noop` means the content already matches the published generation. It is a
    /// success, and the route availability is still recorded so reconciliation knows
    /// whether to keep watching this workout.
    func testNoopReceiptIsTerminalAndKeepsRouteState() {
        let updated = EnrichmentUploader.applyReceipt(
            state: "noop",
            generationNumber: 9,
            failureReason: nil,
            routeAvailability: .pendingEnrichment,
            to: makeJob(),
            now: now
        )

        XCTAssertEqual(updated.state, .noop)
        XCTAssertEqual(updated.routeAvailabilityAtLastPublish, "pending_enrichment")
        XCTAssertTrue(updated.isTerminal)
    }

    /// A non-terminal receipt means the server is still validating; ask again later
    /// rather than assuming either outcome.
    func testStagingOrValidatingReceiptKeepsWaiting() {
        for state in ["staging", "validating"] {
            let updated = EnrichmentUploader.applyReceipt(
                state: state, generationNumber: nil, failureReason: nil,
                routeAvailability: nil, to: makeJob(), now: now
            )
            XCTAssertEqual(updated.state, .awaitingReceipt)
            XCTAssertEqual(updated.attemptCount, 1)
            XCTAssertEqual(updated.nextAttemptAt, now.addingTimeInterval(60))
        }
    }

    /// A failure reason is a server string that could quote validated payload, so only
    /// its presence is recorded — never its content.
    func testFailedReceiptRecordsOnlyAnErrorClass() {
        let updated = EnrichmentUploader.applyReceipt(
            state: "failed",
            generationNumber: nil,
            failureReason: "chunk 3 checksum mismatch for workout ABC-123",
            routeAvailability: nil,
            to: makeJob(),
            now: now
        )

        XCTAssertEqual(updated.state, .failedPermanent)
        XCTAssertEqual(updated.lastErrorClass, "publish_rejected")
        XCTAssertFalse(updated.lastErrorClass?.contains("ABC-123") ?? false)
    }

    /// Repeating `complete` must converge on the same terminal state.
    func testReceiptApplicationIsIdempotent() {
        let first = EnrichmentUploader.applyReceipt(
            state: "published", generationNumber: 4, failureReason: nil,
            routeAvailability: .available, to: makeJob(), now: now
        )
        let second = EnrichmentUploader.applyReceipt(
            state: "published", generationNumber: 4, failureReason: nil,
            routeAvailability: .available, to: first, now: now
        )
        XCTAssertEqual(first, second)
    }

    // MARK: - URLs

    private var base: String { "https://ow.example.com/api/v1" }
    private var userID: String { "user-42" }
    private var uploadID: String { "ba2705987c50cf86a7cf7e7a1a06d255" }

    func testUploadURLsMatchTheContractPaths() {
        XCTAssertEqual(
            EnrichmentUploader.manifestURL(apiBaseURL: base, userID: userID, uploadID: uploadID)?.absoluteString,
            "https://ow.example.com/api/v1/sdk/users/user-42/workout-details/uploads/\(uploadID)"
        )
        XCTAssertEqual(
            EnrichmentUploader.completeURL(apiBaseURL: base, userID: userID, uploadID: uploadID)?.absoluteString,
            "https://ow.example.com/api/v1/sdk/users/user-42/workout-details/uploads/\(uploadID)/complete"
        )
        XCTAssertEqual(
            EnrichmentUploader.tombstonesURL(apiBaseURL: base, userID: userID)?.absoluteString,
            "https://ow.example.com/api/v1/sdk/users/user-42/workout-details/tombstones"
        )
    }

    /// `part_index` is sent for route chunks only.
    func testChunkURLCarriesPartIndexForRoutesOnly() {
        let route = EnrichmentChunkRecord(
            family: "route", chunkIndex: 2, partIndex: 1, fileName: "route_p1_chunk002.json.gz",
            checksum: "", uncompressedBytes: 0, compressedBytes: 0, pointCount: 0, isUploaded: false
        )
        XCTAssertEqual(
            EnrichmentUploader.chunkURL(apiBaseURL: base, userID: userID, uploadID: uploadID, record: route)?.absoluteString,
            "https://ow.example.com/api/v1/sdk/users/user-42/workout-details/uploads/\(uploadID)/chunks/route/2?part_index=1"
        )

        let heartRate = EnrichmentChunkRecord(
            family: "heart_rate", chunkIndex: 0, partIndex: nil, fileName: "heart_rate_chunk000.json.gz",
            checksum: "", uncompressedBytes: 0, compressedBytes: 0, pointCount: 0, isUploaded: false
        )
        XCTAssertEqual(
            EnrichmentUploader.chunkURL(apiBaseURL: base, userID: userID, uploadID: uploadID, record: heartRate)?.absoluteString,
            "https://ow.example.com/api/v1/sdk/users/user-42/workout-details/uploads/\(uploadID)/chunks/heart_rate/0"
        )
    }

    // MARK: - Task descriptions

    /// Task descriptions are visible in system state and survive in crash reports, so
    /// they must carry no path, no user id, and nothing identifying about the workout.
    func testTaskDescriptionCarriesOnlyAHashPrefixAndFileName() throws {
        let description = EnrichmentUploader.taskDescription(uploadID: uploadID, fileName: "route_p0_chunk000.json.gz")
        XCTAssertEqual(description, "enrich|ba270598|route_p0_chunk000.json.gz")

        XCTAssertFalse(description.contains(userID))
        XCTAssertFalse(description.contains("/"))
        XCTAssertFalse(description.contains(uploadID), "only a short prefix may appear")
        XCTAssertFalse(description.contains(WorkoutDetailTestFixtures.workoutUUID))

        let parsed = try XCTUnwrap(EnrichmentUploader.parseTaskDescription(description))
        XCTAssertEqual(parsed.uploadIDPrefix, "ba270598")
        XCTAssertEqual(parsed.fileName, "route_p0_chunk000.json.gz")
    }

    /// A core-sync task description must never be mistaken for an enrichment one.
    func testCoreTaskDescriptionsAreNotParsedAsEnrichment() {
        XCTAssertNil(EnrichmentUploader.parseTaskDescription("/a/item.json|/a/payload.json|/a/anchors.bin"))
        XCTAssertNil(EnrichmentUploader.parseTaskDescription("enrich|only-two-parts"))
        XCTAssertNil(EnrichmentUploader.parseTaskDescription(""))
    }
}
