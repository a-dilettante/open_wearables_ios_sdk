import XCTest
@testable import OpenWearablesHealthSDK

/// The pinned wire contract: upload-id derivation, manifest shape, and the preparation
/// rules that decide what the contract can honestly carry.
///
/// Nothing here touches HealthKit or the network.
final class EnrichmentContractTests: XCTestCase {

    // MARK: - Upload id

    /// Pinned test vector. Both sides derive the upload id from this exact formula, so a
    /// change to the string layout, the prefix length, or the hash is a contract break
    /// that must fail loudly rather than silently produce a different id.
    func testUploadIDMatchesPinnedVector() {
        let rootHash = WorkoutDetailHashing.sha256Hex("abc")
        XCTAssertEqual(rootHash, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        let uploadID = EnrichmentUploadID.derive(
            identityKey: "apple|com.apple.health|SYNC123",
            rootContentHash: rootHash
        )

        XCTAssertEqual(uploadID, "ba2705987c50cf86a7cf7e7a1a06d255")
        XCTAssertEqual(uploadID.count, 32)
        XCTAssertEqual(EnrichmentUploadID.logPrefix(uploadID), "ba270598")
    }

    func testSameContentDerivesSameUploadIDAndRicherContentDerivesNew() {
        let key = "apple|com.acme.runtracker|acme-sync-9f3c1d77"
        let first = EnrichmentUploadID.derive(identityKey: key, rootContentHash: WorkoutDetailHashing.sha256Hex("a"))
        let replay = EnrichmentUploadID.derive(identityKey: key, rootContentHash: WorkoutDetailHashing.sha256Hex("a"))
        let richer = EnrichmentUploadID.derive(identityKey: key, rootContentHash: WorkoutDetailHashing.sha256Hex("a+route"))

        XCTAssertEqual(first, replay, "a retry of identical content must be idempotent")
        XCTAssertNotEqual(first, richer, "richer content must become a new upload")
    }

    /// A trustworthy sync identifier wins over the workout UUID, and the UUID is the
    /// fallback. Start/end time is never part of an identity.
    func testIdentityKeyPrecedence() throws {
        var identity = WorkoutDetailTestFixtures.identity()
        let withSync = EnrichmentIdentityEnvelope(identity)
        XCTAssertEqual(
            withSync.identityKey,
            "apple|\(WorkoutDetailTestFixtures.sourceBundleIdentifier)|\(WorkoutDetailTestFixtures.syncIdentifier)"
        )

        identity.syncIdentifier = nil
        let withoutSync = EnrichmentIdentityEnvelope(identity)
        XCTAssertEqual(withoutSync.identityKey, "apple|\(WorkoutDetailTestFixtures.workoutUUID)")

        // Moving the workout in time must not change its identity.
        identity.startDate = identity.startDate.addingTimeInterval(86_400)
        identity.endDate = identity.endDate.addingTimeInterval(86_400)
        XCTAssertEqual(EnrichmentIdentityEnvelope(identity).identityKey, withoutSync.identityKey)
    }

    // MARK: - Manifest shape

    private func buildManifest() -> [String: Any] {
        let prepared = EnrichmentPreparation.prepare(WorkoutDetailTestFixtures.detail()).detail
        let points = WorkoutDetailTestFixtures.allRoutePoints(prepared)
        // Stand-in chunk checksums: this test asserts the manifest *shape*, and the real
        // checksums only exist once the outbox has encoded the bodies.
        let checksums = ["a", "b"].map { WorkoutDetailHashing.sha256Hex($0) }

        var partHashes: [Int: String] = [:]
        let partSummaries = prepared.route.parts.enumerated().map { index, part -> EnrichmentRoutePartSummary in
            let hash = EnrichmentContentHash.routePart(
                partIndex: index,
                pointCount: part.points.count,
                chunkChecksums: [checksums[index]]
            )
            partHashes[index] = hash
            return EnrichmentRoutePartSummary(
                partIndex: index,
                sourceRouteUUID: part.routeUUID,
                pointCount: part.points.count,
                contentHash: hash
            )
        }

        let route = EnrichmentRouteSummary(
            contentHash: EnrichmentContentHash.routeFamily(pointCount: points.count, partHashes: partHashes),
            chunkCount: partSummaries.count,
            pointCount: points.count,
            uncompressedBytes: 2048,
            availability: .available,
            gapCount: max(0, prepared.route.parts.count - 1),
            bounds: (51.0, 52.0, -1.0, 0.0),
            parts: partSummaries
        )
        let heartRate = EnrichmentStreamSummary(
            contentHash: EnrichmentContentHash.streamFamily(
                metric: prepared.heartRate.metric,
                sourceKey: prepared.heartRate.entries[0].sourceKey,
                pointCount: prepared.heartRate.entries.count,
                chunkChecksums: [checksums[0]]
            ),
            chunkCount: 1,
            pointCount: prepared.heartRate.entries.count,
            uncompressedBytes: 512,
            availability: prepared.heartRate.availability,
            sourceKey: prepared.heartRate.entries[0].sourceKey,
            unit: "count/min",
            axis: "interval",
            sourceTypeIdentifier: prepared.heartRate.quantityTypeIdentifier,
            coverage: (0, 40_000_000),
            gaps: EnrichmentManifestBuilder.declaredGaps(events: prepared.events.events, throughElapsedOffset: 40)
        )

        return EnrichmentManifestBuilder.build(
            detail: prepared,
            route: route,
            heartRate: heartRate,
            eventsHash: EnrichmentContentHash.eventsFamily(
                contentIDs: EnrichmentManifestBuilder.eventContentIDs(prepared)
            ),
            activitiesHash: EnrichmentContentHash.activitiesFamily(
                contentHashes: EnrichmentManifestBuilder.activityContentHashes(prepared)
            )
        )
    }

    func testManifestTopLevelKeysMatchContract() {
        let manifest = buildManifest()
        XCTAssertEqual(Set(manifest.keys), ["schema_version", "identity", "families", "omitted_families"])
        XCTAssertEqual(manifest["schema_version"] as? Int, 1)
        XCTAssertEqual((manifest["omitted_families"] as? [String])?.isEmpty, true)
    }

    func testIdentityKeysMatchContract() throws {
        let identity = try XCTUnwrap(buildManifest()["identity"] as? [String: Any])

        XCTAssertEqual(Set(identity.keys), [
            "provider", "healthkit_workout_uuid", "source_bundle_id", "healthkit_sync_identifier",
            "healthkit_sync_version", "external_uuid", "source_name", "source_version",
            "device_manufacturer", "device_model", "device_product_type",
            "original_timezone_offset", "start_datetime", "end_datetime", "workout_type"
        ])
        XCTAssertEqual(identity["provider"] as? String, "apple")
        XCTAssertEqual(identity["original_timezone_offset"] as? String, "+01:00")

        // ISO 8601 with an explicit offset, in the workout's original zone.
        let start = try XCTUnwrap(identity["start_datetime"] as? String)
        XCTAssertTrue(start.hasSuffix("+01:00"), "start_datetime must carry the original offset")
    }

    func testFamilyKeysMatchContract() throws {
        let families = try XCTUnwrap(buildManifest()["families"] as? [String: Any])
        XCTAssertEqual(Set(families.keys), ["route", "heart_rate", "events", "activities"])

        let route = try XCTUnwrap(families["route"] as? [String: Any])
        XCTAssertEqual(Set(route.keys), [
            "content_hash", "chunk_count", "point_count", "uncompressed_bytes",
            "availability", "gap_count", "bounds", "parts"
        ])
        XCTAssertEqual((route["content_hash"] as? String)?.count, 64)
        // Two route objects means exactly one source-declared discontinuity.
        XCTAssertEqual(route["gap_count"] as? Int, 1)

        let parts = try XCTUnwrap(route["parts"] as? [[String: Any]])
        XCTAssertEqual(Set(parts[0].keys), ["part_index", "source_route_uuid", "point_count", "content_hash"])

        let heartRate = try XCTUnwrap(families["heart_rate"] as? [String: Any])
        XCTAssertEqual(Set(heartRate.keys), [
            "content_hash", "chunk_count", "point_count", "uncompressed_bytes", "availability",
            "source_key", "unit", "axis", "source_type_identifier", "coverage", "gaps"
        ])
        XCTAssertEqual(heartRate["unit"] as? String, "count/min")
        XCTAssertEqual(heartRate["axis"] as? String, "interval")

        let coverage = try XCTUnwrap(heartRate["coverage"] as? [String: Any])
        XCTAssertEqual(Set(coverage.keys), ["observed_from_elapsed_us", "observed_through_elapsed_us"])
    }

    func testInlineEventEntriesMatchContract() throws {
        let families = try XCTUnwrap(buildManifest()["families"] as? [String: Any])
        let events = try XCTUnwrap(families["events"] as? [String: Any])
        XCTAssertEqual(Set(events.keys), ["content_hash", "entries"])

        let entries = try XCTUnwrap(events["entries"] as? [[String: Any]])
        XCTAssertEqual(Set(entries[0].keys), [
            "event_index", "event_type", "start_timestamp", "end_timestamp",
            "start_elapsed_us", "end_elapsed_us", "content_id", "source_metadata"
        ])

        // Every emitted type is one the contract enumerates.
        let allowed: Set<String> = ["pause", "resume", "automatic_pause", "automatic_resume", "lap", "segment", "marker"]
        for entry in entries {
            XCTAssertTrue(allowed.contains(entry["event_type"] as? String ?? ""))
        }

        // A zero-duration legacy lap keeps its zero duration: no synthetic end.
        let lap = try XCTUnwrap(entries.first { $0["event_type"] as? String == "lap" })
        XCTAssertTrue(lap["end_timestamp"] is NSNull)
        XCTAssertTrue(lap["end_elapsed_us"] is NSNull)
        XCTAssertEqual(lap["start_elapsed_us"] as? Int, 600_000_000)
    }

    func testInlineActivityEntriesMatchContract() throws {
        let families = try XCTUnwrap(buildManifest()["families"] as? [String: Any])
        let activities = try XCTUnwrap(families["activities"] as? [String: Any])
        let entries = try XCTUnwrap(activities["entries"] as? [[String: Any]])

        XCTAssertEqual(Set(entries[0].keys), [
            "position", "activity_uuid", "activity_type", "start_timestamp", "end_timestamp",
            "start_elapsed_us", "end_elapsed_us", "statistics", "configuration", "content_hash"
        ])
        XCTAssertEqual((entries[0]["content_hash"] as? String)?.count, 64)
    }

    /// A family left out of an upload must be listed as omitted, which is what tells the
    /// server to leave the published family alone rather than clear it.
    func testOmittedFamiliesAreDeclared() {
        let prepared = EnrichmentPreparation.prepare(WorkoutDetailTestFixtures.detail()).detail
        let manifest = EnrichmentManifestBuilder.build(
            detail: prepared,
            route: nil,
            heartRate: nil,
            eventsHash: nil,
            activitiesHash: EnrichmentContentHash.activitiesFamily(
                contentHashes: EnrichmentManifestBuilder.activityContentHashes(prepared)
            )
        )

        XCTAssertEqual(
            Set(manifest["omitted_families"] as? [String] ?? []),
            ["route", "heart_rate", "events"]
        )
        XCTAssertEqual(Set((manifest["families"] as? [String: Any] ?? [:]).keys), ["activities"])
    }

    /// The manifest must survive `JSONSerialization`, which rejects a stray Swift
    /// optional or tuple.
    func testManifestIsSerializable() {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(buildManifest()))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: buildManifest()))
    }

    // MARK: - Preparation

    /// The fixture mixes a watch and a chest strap. The contract pins one source per
    /// stream, so the dominant one is sent and the family is honestly `partial` — the
    /// alternative, merging them, would invent a single sensor that never existed.
    func testMultipleHeartRateSourcesKeepDominantAndReportPartial() {
        let result = EnrichmentPreparation.prepare(WorkoutDetailTestFixtures.detail())

        XCTAssertEqual(result.droppedForeignSourceEntryCount, 1)
        XCTAssertEqual(Set(result.detail.heartRate.entries.map { $0.sourceKey }).count, 1)
        XCTAssertEqual(result.detail.heartRate.entries[0].sourceKey, WorkoutDetailTestFixtures.sourceKey)
        XCTAssertEqual(result.detail.heartRate.availability, .partial)
    }

    /// A native type the contract cannot express is dropped, never flattened into a
    /// neighbouring type, and the family says so.
    func testUnmappableEventIsDroppedNotFlattened() {
        var detail = WorkoutDetailTestFixtures.detail()
        detail.events.events.append(WorkoutEventEntry(
            typeRawValue: 8, typeName: "pause_or_resume_request",
            startDate: WorkoutDetailTestFixtures.workoutStart.addingTimeInterval(30),
            endDate: WorkoutDetailTestFixtures.workoutStart.addingTimeInterval(30),
            startElapsedOffset: 30, endElapsedOffset: 30, ordinal: 9
        ))

        let result = EnrichmentPreparation.prepare(detail)
        XCTAssertEqual(result.droppedUnmappableEventCount, 1)
        XCTAssertFalse(result.detail.events.events.contains { $0.typeRawValue == 8 })
        XCTAssertEqual(result.detail.events.availability, .partial)
        XCTAssertNil(EnrichmentWire.wireEventType(forHealthKitRawValue: 8))
    }

    func testMotionPausesMapToAutomaticPauseAndResume() {
        XCTAssertEqual(EnrichmentWire.wireEventType(forHealthKitRawValue: 5), "automatic_pause")
        XCTAssertEqual(EnrichmentWire.wireEventType(forHealthKitRawValue: 6), "automatic_resume")
        XCTAssertNil(EnrichmentWire.wireEventType(forHealthKitRawValue: 99), "a future type must not be guessed")
    }

    /// An absent route is `pending_enrichment` while the source may still write one, and
    /// only afterwards `not_available_or_not_authorized`.
    func testRouteAvailabilityWaitsForLateRoutes() {
        let empty = WorkoutRouteDetail(availability: .notAvailableOrNotAuthorized)
        let end = Date()

        XCTAssertEqual(
            EnrichmentPreparation.routeAvailability(empty, workoutEnd: end, now: end.addingTimeInterval(3600)),
            .pendingEnrichment
        )
        XCTAssertEqual(
            EnrichmentPreparation.routeAvailability(empty, workoutEnd: end, now: end.addingTimeInterval(25 * 3600)),
            .notAvailableOrNotAuthorized
        )
        // A route that was read keeps whatever it reported.
        XCTAssertEqual(
            EnrichmentPreparation.routeAvailability(
                WorkoutDetailTestFixtures.route(), workoutEnd: end, now: end
            ),
            .available
        )
    }

    // MARK: - Gaps

    /// Gaps come from the source's own pause/resume events. No sampling-interval
    /// threshold is applied, because HealthKit publishes no cadence to compare against.
    func testGapsComeFromDeclaredPauses() {
        let gaps = EnrichmentManifestBuilder.declaredGaps(
            events: WorkoutDetailTestFixtures.events().events,
            throughElapsedOffset: 2700
        )

        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].startElapsedMicroseconds, 1_500_000_000)
        XCTAssertEqual(gaps[0].endElapsedMicroseconds, 1_620_000_000)
    }

    func testUnmatchedPauseClosesAtObservedEnd() {
        let events = [
            WorkoutEventEntry(
                typeRawValue: 1, typeName: "pause",
                startDate: WorkoutDetailTestFixtures.workoutStart.addingTimeInterval(100),
                endDate: WorkoutDetailTestFixtures.workoutStart.addingTimeInterval(100),
                startElapsedOffset: 100, endElapsedOffset: 100, ordinal: 0
            )
        ]

        let gaps = EnrichmentManifestBuilder.declaredGaps(events: events, throughElapsedOffset: 500)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].endElapsedMicroseconds, 500_000_000)

        // With nothing observed after the pause there is no defensible end, so no gap.
        XCTAssertTrue(EnrichmentManifestBuilder.declaredGaps(events: events, throughElapsedOffset: nil).isEmpty)
    }

    // MARK: - Scalars

    func testElapsedMicrosecondsAndOffsetLabels() {
        XCTAssertEqual(EnrichmentWire.elapsedMicroseconds(1.5), 1_500_000)
        XCTAssertEqual(EnrichmentWire.elapsedMicroseconds(-0.25), -250_000)
        XCTAssertEqual(EnrichmentWire.elapsedMicroseconds(.nan), 0)

        XCTAssertEqual(EnrichmentWire.offsetLabel(3600), "+01:00")
        XCTAssertEqual(EnrichmentWire.offsetLabel(-19_800), "-05:30")
        XCTAssertEqual(EnrichmentWire.offsetLabel(0), "+00:00")
    }

    // MARK: - Tombstone

    /// A tombstone is built from the stored envelope, so it still works after the
    /// workout has been deleted from HealthKit and can no longer be read.
    func testTombstoneBodyUsesStoredIdentityOnly() throws {
        let envelope = EnrichmentIdentityEnvelope(WorkoutDetailTestFixtures.identity())
        let deletedAt = Date(timeIntervalSince1970: 946_684_800)
        let body = envelope.tombstoneObject(deletedAt: deletedAt)

        XCTAssertEqual(Set(body.keys), ["schema_version", "identity", "deleted_at"])
        XCTAssertEqual(body["schema_version"] as? Int, 1)
        // A deletion is recorded in UTC, which ISO 8601 designates with `Z` rather than
        // a numeric `+00:00` offset. Both are the same instant and both parse.
        XCTAssertEqual(body["deleted_at"] as? String, "2000-01-01T00:00:00.000Z")

        let identity = try XCTUnwrap(body["identity"] as? [String: Any])
        XCTAssertEqual(
            Set(identity.keys),
            ["provider", "healthkit_workout_uuid", "source_bundle_id", "healthkit_sync_identifier"]
        )
        XCTAssertEqual(identity["healthkit_workout_uuid"] as? String, WorkoutDetailTestFixtures.workoutUUID)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
    }
}
