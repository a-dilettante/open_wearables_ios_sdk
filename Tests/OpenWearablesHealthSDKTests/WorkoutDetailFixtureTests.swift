import XCTest
@testable import OpenWearablesHealthSDK

/// Fixture structure: what redaction must preserve.
///
/// Redaction is only useful if the fixture still behaves like the workout it came
/// from. These tests pin the properties downstream phases depend on.
final class WorkoutDetailFixtureTests: XCTestCase {

    private let key = "phase0-test-key"

    private func fixtureObject(_ detail: CollectedWorkoutDetail? = nil) throws -> [String: Any] {
        let source = detail ?? WorkoutDetailTestFixtures.detail()
        let data = try WorkoutDetailFixtureWriter.makeFixtureData(from: source, key: key)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Manifest

    func testManifestReportsVersionsAndCounts() throws {
        let manifest = try XCTUnwrap(fixtureObject()["manifest"] as? [String: Any])
        XCTAssertEqual(manifest["schema_version"] as? Int, CollectedWorkoutDetail.schemaVersion)
        XCTAssertEqual(manifest["redaction_version"] as? Int, WorkoutDetailFixtureWriter.redactionVersion)
        XCTAssertEqual(manifest["synthetic_epoch"] as? String, "2000-01-01T00:00:00.000Z")

        let detail = WorkoutDetailTestFixtures.detail()
        let counts = try XCTUnwrap(manifest["counts"] as? [String: Any])
        XCTAssertEqual(counts["route_parts"] as? Int, detail.route.parts.count)
        XCTAssertEqual(counts["route_points"] as? Int, detail.route.pointCount)
        XCTAssertEqual(counts["heart_rate_entries"] as? Int, detail.heartRate.entries.count)
        XCTAssertEqual(counts["events"] as? Int, detail.events.events.count)
        XCTAssertEqual(counts["activities"] as? Int, detail.activities.activities.count)
    }

    // MARK: - Determinism

    func testFixtureBytesAreDeterministic() throws {
        let detail = WorkoutDetailTestFixtures.detail()
        let first = try WorkoutDetailFixtureWriter.makeFixtureData(from: detail, key: key)
        let second = try WorkoutDetailFixtureWriter.makeFixtureData(from: detail, key: key)
        XCTAssertEqual(first, second, "same input and key must produce identical bytes")
    }

    func testDifferentKeyProducesDifferentFixture() throws {
        let detail = WorkoutDetailTestFixtures.detail()
        let a = try WorkoutDetailFixtureWriter.makeFixtureData(from: detail, key: "key-a")
        let b = try WorkoutDetailFixtureWriter.makeFixtureData(from: detail, key: "key-b")
        XCTAssertNotEqual(a, b)
    }

    func testPermutedInputProducesIdenticalFixture() throws {
        // The writer emits in canonical order, so arrival order cannot leak in.
        let ordered = try WorkoutDetailFixtureWriter.makeFixtureData(from: WorkoutDetailTestFixtures.detail(), key: key)
        let permuted = try WorkoutDetailFixtureWriter.makeFixtureData(from: WorkoutDetailTestFixtures.permutedDetail(), key: key)
        XCTAssertEqual(ordered, permuted)
    }

    // MARK: - Offsets and gaps

    func testEveryRouteOffsetAndGapIsPreserved() throws {
        let detail = WorkoutDetailTestFixtures.detail()
        let route = try XCTUnwrap(fixtureObject()["route"] as? [String: Any])
        let parts = try XCTUnwrap(route["parts"] as? [[String: Any]])

        let expectedParts = WorkoutDetailHashing.sortedParts(detail.route.parts)
        XCTAssertEqual(parts.count, expectedParts.count)

        var emittedOffsets: [Double] = []
        for (part, expectedPart) in zip(parts, expectedParts) {
            let points = try XCTUnwrap(part["points"] as? [[String: Any]])
            let expectedPoints = WorkoutDetailHashing.sortedPoints(expectedPart.points)
            XCTAssertEqual(points.count, expectedPoints.count)
            for (point, expected) in zip(points, expectedPoints) {
                XCTAssertEqual(point["elapsed_offset_s"] as? Double, expected.elapsedOffset)
                XCTAssertEqual(point["ordinal"] as? Int, expected.ordinal)
                emittedOffsets.append(try XCTUnwrap(point["elapsed_offset_s"] as? Double))
            }
        }

        // The 300s gap between the two route parts must still be visible.
        let gaps = zip(emittedOffsets, emittedOffsets.dropFirst()).map { $1 - $0 }
        XCTAssertTrue(gaps.contains { $0 > 250 }, "the inter-part gap must survive redaction")
        // And the irregular sub-second spacing must not have been regularised.
        XCTAssertTrue(Set(gaps).count > 3, "spacing must stay irregular, not resampled to a fixed cadence")
    }

    func testAccuracyAndMotionValuesArePreservedIncludingNils() throws {
        let detail = WorkoutDetailTestFixtures.detail()
        let route = try XCTUnwrap(fixtureObject()["route"] as? [String: Any])
        let parts = try XCTUnwrap(route["parts"] as? [[String: Any]])
        let points = try XCTUnwrap(parts[0]["points"] as? [[String: Any]])
        let expected = WorkoutDetailHashing.sortedPoints(WorkoutDetailHashing.sortedParts(detail.route.parts)[0].points)

        for (point, source) in zip(points, expected) {
            XCTAssertEqual(point["horizontal_accuracy_m"] as? Double, source.horizontalAccuracy)
            XCTAssertEqual(point["altitude_m"] as? Double, source.altitude)
            XCTAssertEqual(point["speed_mps"] as? Double, source.speed)
            if source.verticalAccuracy == nil {
                // A missing measurement must stay missing, not become zero.
                XCTAssertTrue(point["vertical_accuracy_m"] is NSNull)
            } else {
                XCTAssertEqual(point["vertical_accuracy_m"] as? Double, source.verticalAccuracy)
            }
        }
    }

    func testTimestampsAreRebasedOntoSyntheticEpochPreservingOffsets() throws {
        let identity = try XCTUnwrap(fixtureObject()["identity"] as? [String: Any])
        XCTAssertEqual(identity["start_date"] as? String, "2000-01-01T00:00:00.000Z")
        // 2700s after the synthetic epoch, matching the real 45-minute span.
        XCTAssertEqual(identity["end_date"] as? String, "2000-01-01T00:45:00.000Z")
        XCTAssertEqual(identity["duration_s"] as? Double, 2580)
        XCTAssertEqual(identity["span_s"] as? Double, 2700)
    }

    // MARK: - Interval semantics

    func testCondensedIntervalSemanticsArePreserved() throws {
        let heartRate = try XCTUnwrap(fixtureObject()["heart_rate"] as? [String: Any])
        let entries = try XCTUnwrap(heartRate["entries"] as? [[String: Any]])
        let expected = WorkoutDetailHashing.sortedEntries(WorkoutDetailTestFixtures.detail().heartRate.entries)

        XCTAssertEqual(entries.count, expected.count)
        for (entry, source) in zip(entries, expected) {
            XCTAssertEqual(entry["kind"] as? String, source.kind.rawValue)
            XCTAssertEqual(entry["start_elapsed_offset_s"] as? Double, source.startElapsedOffset)
            XCTAssertEqual(entry["end_elapsed_offset_s"] as? Double, source.endElapsedOffset)
            XCTAssertEqual(entry["value"] as? Double, source.value)
            XCTAssertEqual(entry["unit"] as? String, source.unit)
            XCTAssertEqual(entry["expanded_from_series"] as? Bool, source.isExpandedFromSeries)
            XCTAssertEqual(entry["parent_series_count"] as? Int, source.parentSeriesCount)
        }

        // The coalesced interval keeps its span rather than being split into points.
        let interval = try XCTUnwrap(entries.first { $0["kind"] as? String == "interval" })
        XCTAssertEqual(interval["start_elapsed_offset_s"] as? Double, 10)
        XCTAssertEqual(interval["end_elapsed_offset_s"] as? Double, 25)
        XCTAssertEqual(interval["parent_series_count"] as? Int, 12)

        // Outer sample count never equals expanded entry count.
        XCTAssertEqual(heartRate["top_level_sample_count"] as? Int, 4)
        XCTAssertEqual(heartRate["entry_count"] as? Int, 5)
    }

    func testDistinctSourcesAtTheSameOffsetStayDistinct() throws {
        let heartRate = try XCTUnwrap(fixtureObject()["heart_rate"] as? [String: Any])
        let entries = try XCTUnwrap(heartRate["entries"] as? [[String: Any]])
        let atForty = entries.filter { ($0["start_elapsed_offset_s"] as? Double) == 40 }

        XCTAssertEqual(atForty.count, 2, "equal timestamps must not be deduplicated")
        let sourceKeys = Set(atForty.compactMap { $0["source_key"] as? String })
        XCTAssertEqual(sourceKeys.count, 2, "two recorders must map to two distinct synthetic source keys")
    }

    // MARK: - Event boundaries

    func testEventBoundariesAndZeroDurationLapsArePreserved() throws {
        let events = try XCTUnwrap(fixtureObject()["events"] as? [String: Any])
        let entries = try XCTUnwrap(events["events"] as? [[String: Any]])
        let expected = WorkoutDetailHashing.sortedEvents(WorkoutDetailTestFixtures.detail().events.events)

        XCTAssertEqual(entries.count, expected.count)
        for (entry, source) in zip(entries, expected) {
            XCTAssertEqual(entry["type_raw"] as? Int, source.typeRawValue)
            XCTAssertEqual(entry["type_name"] as? String, source.typeName)
            XCTAssertEqual(entry["start_elapsed_offset_s"] as? Double, source.startElapsedOffset)
            XCTAssertEqual(entry["end_elapsed_offset_s"] as? Double, source.endElapsedOffset)
            XCTAssertEqual(entry["zero_duration"] as? Bool, source.isZeroDuration)
        }

        let lap = try XCTUnwrap(entries.first { $0["type_name"] as? String == "lap" })
        XCTAssertEqual(lap["zero_duration"] as? Bool, true, "a legacy zero-duration lap must not be widened")
        XCTAssertEqual(lap["start_elapsed_offset_s"] as? Double, lap["end_elapsed_offset_s"] as? Double)

        // Overlapping segments both survive.
        let segments = entries.filter { $0["type_name"] as? String == "segment" }
        XCTAssertEqual(segments.count, 2)
    }

    func testFreeTextMetadataIsTokenisedButNumericMetadataIsKept() throws {
        let redacted = WorkoutDetailFixtureWriter.redactedMetadata(
            ["HKMetadataKeySegmentLabel": "warmup", "acmeNote": "Alexs tempo block", "HKMetadataKeyLapLength": "400"],
            key: key
        )
        // Numeric metadata is structural and is kept.
        XCTAssertEqual(redacted["HKMetadataKeyLapLength"] as? Double, 400)
        // Free text could hold a title, place, or user name, so it is tokenised.
        XCTAssertNotEqual(redacted["HKMetadataKeySegmentLabel"] as? String, "warmup")
        // A non-Apple key is itself tokenised.
        XCTAssertNil(redacted["acmeNote"])
        XCTAssertEqual(redacted.count, 3)
    }

    // MARK: - Route geometry

    func testRotationPreservesPairwiseDistances() throws {
        let detail = WorkoutDetailTestFixtures.detail()
        let originalPoints = WorkoutDetailTestFixtures.allRoutePoints(detail)

        let route = try XCTUnwrap(fixtureObject()["route"] as? [String: Any])
        let parts = try XCTUnwrap(route["parts"] as? [[String: Any]])
        var redactedPoints: [(latitude: Double, longitude: Double)] = []
        for part in parts {
            for point in try XCTUnwrap(part["points"] as? [[String: Any]]) {
                redactedPoints.append((
                    try XCTUnwrap(point["latitude"] as? Double),
                    try XCTUnwrap(point["longitude"] as? Double)
                ))
            }
        }
        XCTAssertEqual(redactedPoints.count, originalPoints.count)

        // Every pair, not just consecutive ones: a translation-only redaction would
        // pass a consecutive check while a broken rotation would not preserve shape.
        var comparisons = 0
        for i in 0..<originalPoints.count {
            for j in (i + 1)..<originalPoints.count {
                let originalDistance = WorkoutDetailTestFixtures.haversineMetres(
                    (originalPoints[i].latitude, originalPoints[i].longitude),
                    (originalPoints[j].latitude, originalPoints[j].longitude)
                )
                let redactedDistance = WorkoutDetailTestFixtures.haversineMetres(
                    redactedPoints[i], redactedPoints[j]
                )
                // Equirectangular projection over a workout-sized extent: sub-metre.
                XCTAssertEqual(redactedDistance, originalDistance, accuracy: max(0.5, originalDistance * 0.001))
                comparisons += 1
            }
        }
        XCTAssertGreaterThan(comparisons, 50)
    }

    func testFirstPointIsAnchoredToSyntheticOrigin() throws {
        let route = try XCTUnwrap(fixtureObject()["route"] as? [String: Any])
        let parts = try XCTUnwrap(route["parts"] as? [[String: Any]])
        let firstPoint = try XCTUnwrap((parts[0]["points"] as? [[String: Any]])?.first)

        XCTAssertEqual(try XCTUnwrap(firstPoint["latitude"] as? Double), 0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(firstPoint["longitude"] as? Double), 0, accuracy: 1e-12)
        XCTAssertEqual(route["rotation_applied"] as? Bool, true)
    }

    func testRotationAngleIsDeterministicAndKeyDependent() {
        XCTAssertEqual(
            WorkoutDetailFixtureWriter.rotationAngle(key: "alpha"),
            WorkoutDetailFixtureWriter.rotationAngle(key: "alpha")
        )
        XCTAssertNotEqual(
            WorkoutDetailFixtureWriter.rotationAngle(key: "alpha"),
            WorkoutDetailFixtureWriter.rotationAngle(key: "beta")
        )
        let angle = WorkoutDetailFixtureWriter.rotationAngle(key: "alpha")
        XCTAssertTrue(angle >= 0 && angle < 2 * Double.pi)
    }

    func testRotationActuallyMovesGeometry() {
        // A rotation of ~0 would leave the shape recognisable in place; the fixture key
        // used by the tests must produce a real rotation.
        let angle = WorkoutDetailFixtureWriter.rotationAngle(key: key)
        let moved = WorkoutDetailFixtureWriter.redactCoordinate(
            latitude: WorkoutDetailTestFixtures.originLatitude + 0.01,
            longitude: WorkoutDetailTestFixtures.originLongitude,
            origin: (WorkoutDetailTestFixtures.originLatitude, WorkoutDetailTestFixtures.originLongitude),
            angle: angle
        )
        // Due north originally; after a non-trivial rotation it must gain an east/west
        // component rather than staying purely north.
        XCTAssertGreaterThan(abs(moved.longitude), 1e-5)
    }

    // MARK: - Missing families

    func testWorkoutWithNoRouteStillProducesValidFixture() throws {
        var detail = WorkoutDetailTestFixtures.detail()
        detail.route = WorkoutRouteDetail(availability: .notAvailableOrNotAuthorized)

        let object = try fixtureObject(detail)
        let route = try XCTUnwrap(object["route"] as? [String: Any])
        XCTAssertEqual(route["availability"] as? String, "not_available_or_not_authorized")
        XCTAssertEqual((route["parts"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(route["rotation_applied"] as? Bool, false)

        // A missing route must never suppress heart rate.
        let heartRate = try XCTUnwrap(object["heart_rate"] as? [String: Any])
        XCTAssertEqual(heartRate["availability"] as? String, "available")
        XCTAssertEqual(heartRate["entry_count"] as? Int, 5)
    }

    func testIOS15ActivitiesReportUnsupportedRatherThanEmpty() throws {
        var detail = WorkoutDetailTestFixtures.detail()
        detail.activities = WorkoutActivitiesDetail(
            availability: .notAvailableOrNotAuthorized,
            isSupportedOnThisOS: false
        )

        let activities = try XCTUnwrap(fixtureObject(detail)["activities"] as? [String: Any])
        XCTAssertEqual(activities["os_supported"] as? Bool, false)
        XCTAssertEqual(activities["activity_count"] as? Int, 0)
    }
}
