import XCTest
@testable import OpenWearablesHealthSDK

/// Hashing determinism and the pure mapping helpers.
///
/// Nothing here touches HealthKit, so the suite runs without entitlements.
final class WorkoutDetailHashingTests: XCTestCase {

    // MARK: - Determinism

    func testSameInputProducesSameHashes() {
        let first = WorkoutDetailHashing.hashes(for: WorkoutDetailTestFixtures.detail())
        let second = WorkoutDetailHashing.hashes(for: WorkoutDetailTestFixtures.detail())
        XCTAssertEqual(first, second)
    }

    func testPermutedInputProducesSameHashesAfterCanonicalSort() {
        let ordered = WorkoutDetailHashing.hashes(for: WorkoutDetailTestFixtures.detail())
        let permuted = WorkoutDetailHashing.hashes(for: WorkoutDetailTestFixtures.permutedDetail())

        XCTAssertEqual(ordered.route, permuted.route, "route parts and points must sort canonically")
        XCTAssertEqual(ordered.heartRate, permuted.heartRate, "heart-rate entries must sort canonically")
        XCTAssertEqual(ordered.events, permuted.events, "events must sort canonically")
        XCTAssertEqual(ordered.activities, permuted.activities, "activities must sort canonically")
        XCTAssertEqual(ordered.root, permuted.root)
    }

    func testChangedValueProducesDifferentHash() {
        let baseline = WorkoutDetailHashing.hashes(for: WorkoutDetailTestFixtures.detail())

        var mutated = WorkoutDetailTestFixtures.detail()
        mutated.heartRate.entries[0].value += 1

        let changed = WorkoutDetailHashing.hashes(for: mutated)
        XCTAssertNotEqual(baseline.heartRate, changed.heartRate)
        XCTAssertNotEqual(baseline.root, changed.root)
        // Independent families: a heart-rate edit must not disturb the route hash.
        XCTAssertEqual(baseline.route, changed.route)
        XCTAssertEqual(baseline.events, changed.events)
    }

    func testMovedCoordinateProducesDifferentRouteHash() {
        let baseline = WorkoutDetailHashing.hashes(for: WorkoutDetailTestFixtures.detail())

        var mutated = WorkoutDetailTestFixtures.detail()
        // A sub-metre move must still change the hash — coordinates keep 9 decimals.
        mutated.route.parts[0].points[0].latitude += 0.000_001

        XCTAssertNotEqual(baseline.route, WorkoutDetailHashing.hashes(for: mutated).route)
    }

    func testIntervalSemanticsAffectHash() {
        var mutated = WorkoutDetailTestFixtures.detail()
        let index = mutated.heartRate.entries.firstIndex { $0.kind == .interval }
        XCTAssertNotNil(index, "fixture must contain a coalesced interval")

        // Collapsing an interval into a point is a fidelity loss and must be visible.
        mutated.heartRate.entries[index!].kind = .point
        XCTAssertNotEqual(
            WorkoutDetailHashing.hashes(for: WorkoutDetailTestFixtures.detail()).heartRate,
            WorkoutDetailHashing.hashes(for: mutated).heartRate
        )
    }

    // MARK: - Cross-process stability

    func testDigestIsStandardSHA256() {
        // Known answer. Proves the digest is real SHA-256 and therefore identical in
        // any process, on any architecture, in any future run.
        XCTAssertEqual(
            WorkoutDetailHashing.sha256Hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testCanonicalTextContainsNoAbsoluteDates() {
        // Absolute time must never enter a hash: a logged hash prefix would otherwise
        // be derived from when the user exercised.
        let detail = WorkoutDetailTestFixtures.detail()
        let canonical = [
            WorkoutDetailHashing.canonicalIdentity(detail.identity),
            WorkoutDetailHashing.canonicalRoute(detail.route),
            WorkoutDetailHashing.canonicalQuantityStream(detail.heartRate),
            WorkoutDetailHashing.canonicalEvents(detail.events),
            WorkoutDetailHashing.canonicalActivities(detail.activities)
        ].joined()

        XCTAssertFalse(canonical.contains(WorkoutDetailTestFixtures.workoutStartDay))
        XCTAssertFalse(canonical.contains(String(Int(WorkoutDetailTestFixtures.workoutStart.timeIntervalSince1970))))
    }

    func testMetadataOrderDoesNotAffectCanonicalText() {
        // Swift seeds dictionary iteration per process, so metadata must be key-sorted
        // or the same workout would hash differently on each launch.
        let forward = ["alpha": "1", "beta": "2", "gamma": "3"]
        var reverse: [String: String] = [:]
        reverse["gamma"] = "3"
        reverse["beta"] = "2"
        reverse["alpha"] = "1"

        XCTAssertEqual(
            WorkoutDetailHashing.canonicalMetadata(forward),
            WorkoutDetailHashing.canonicalMetadata(reverse)
        )
        XCTAssertEqual(WorkoutDetailHashing.canonicalMetadata(forward), "alpha=1;beta=2;gamma=3")
    }

    func testNegativeZeroIsNormalised() {
        // -0.0 and 0.0 are equal but format differently, which would break stability.
        XCTAssertEqual(WorkoutDetailHashing.num(-0.0), WorkoutDetailHashing.num(0.0))
        XCTAssertEqual(WorkoutDetailHashing.coord(-0.0), WorkoutDetailHashing.coord(0.0))
    }

    func testNonFiniteValuesAreRenderedNotCrashed() {
        XCTAssertEqual(WorkoutDetailHashing.num(.nan), "nan")
        XCTAssertEqual(WorkoutDetailHashing.num(.infinity), "inf")
        XCTAssertEqual(WorkoutDetailHashing.num(-.infinity), "-inf")
        XCTAssertEqual(WorkoutDetailHashing.optionalNum(nil), "-")
    }

    func testCoordinatePrecisionRetainsAtLeastSixDecimals() {
        // The acceptance gate requires six decimal places to survive.
        XCTAssertEqual(WorkoutDetailHashing.coord(51.507351), "51.507351000")
        XCTAssertNotEqual(WorkoutDetailHashing.coord(51.507351), WorkoutDetailHashing.coord(51.507352))
    }

    func testKeyedHexIsStableAndKeyDependent() {
        XCTAssertEqual(
            WorkoutDetailHashing.keyedHex("workout-1", key: "k1"),
            WorkoutDetailHashing.keyedHex("workout-1", key: "k1")
        )
        XCTAssertNotEqual(
            WorkoutDetailHashing.keyedHex("workout-1", key: "k1"),
            WorkoutDetailHashing.keyedHex("workout-1", key: "k2")
        )
        XCTAssertNotEqual(
            WorkoutDetailHashing.keyedHex("workout-1", key: "k1"),
            WorkoutDetailHashing.keyedHex("workout-2", key: "k1")
        )
    }

    // MARK: - Canonical ordering

    func testEqualOffsetsAreOrderedByOrdinalAndKept() {
        let detail = WorkoutDetailTestFixtures.detail()
        let sorted = WorkoutDetailHashing.sortedEntries(detail.heartRate.entries)
        let atFortySeconds = sorted.filter { $0.startElapsedOffset == 40 }

        // Equal timestamps are legal and must not be deduplicated.
        XCTAssertEqual(atFortySeconds.count, 2)
        XCTAssertEqual(atFortySeconds.map { $0.ordinal }, [3, 4])
    }

    func testSortedEntriesAreMonotonicByOffsetThenOrdinal() {
        let sorted = WorkoutDetailHashing.sortedEntries(WorkoutDetailTestFixtures.permutedDetail().heartRate.entries)
        for (previous, next) in zip(sorted, sorted.dropFirst()) {
            let ordered = previous.startElapsedOffset < next.startElapsedOffset
                || (previous.startElapsedOffset == next.startElapsedOffset
                    && previous.endElapsedOffset <= next.endElapsedOffset)
            XCTAssertTrue(ordered)
        }
    }

    func testOverlappingSegmentsAreBothRetained() {
        let sorted = WorkoutDetailHashing.sortedEvents(WorkoutDetailTestFixtures.detail().events.events)
        let segments = sorted.filter { $0.typeName == "segment" }

        XCTAssertEqual(segments.count, 2, "segments may overlap and both must survive")
        XCTAssertTrue(segments[0].endElapsedOffset > segments[1].startElapsedOffset, "fixture must actually overlap")
    }

    // MARK: - Pure mapping layer

    func testElapsedOffsetIsNotClamped() {
        let start = WorkoutDetailTestFixtures.workoutStart
        // A source may write a location just before the workout start; preserve it.
        XCTAssertEqual(WorkoutDetailMapping.elapsedOffset(of: start.addingTimeInterval(-2), from: start), -2)
        XCTAssertEqual(WorkoutDetailMapping.elapsedOffset(of: start.addingTimeInterval(90), from: start), 90)
    }

    func testEntryKindDistinguishesPointFromInterval() {
        let start = WorkoutDetailTestFixtures.workoutStart
        XCTAssertEqual(WorkoutDetailMapping.entryKind(start: start, end: start), .point)
        XCTAssertEqual(WorkoutDetailMapping.entryKind(start: start, end: start.addingTimeInterval(5)), .interval)
    }

    func testInvalidMeasurementsBecomeNilRatherThanZero() {
        // CoreLocation signals "unknown" with a negative value. Zero would be a lie.
        XCTAssertNil(WorkoutDetailMapping.validMeasurement(-1))
        XCTAssertNil(WorkoutDetailMapping.validMeasurement(.nan))
        XCTAssertEqual(WorkoutDetailMapping.validMeasurement(4.0), 4.0)
        XCTAssertEqual(WorkoutDetailMapping.validMeasurement(0), 0)
        // Altitude is signed: below sea level is real.
        XCTAssertEqual(WorkoutDetailMapping.validSignedMeasurement(-12.5), -12.5)
        XCTAssertNil(WorkoutDetailMapping.validSignedMeasurement(.infinity))
    }

    func testEventTypeNamesCoverEveryNativeCaseAndPreserveUnknowns() {
        XCTAssertEqual(WorkoutDetailMapping.eventTypeName(rawValue: 1), "pause")
        XCTAssertEqual(WorkoutDetailMapping.eventTypeName(rawValue: 2), "resume")
        XCTAssertEqual(WorkoutDetailMapping.eventTypeName(rawValue: 3), "lap")
        XCTAssertEqual(WorkoutDetailMapping.eventTypeName(rawValue: 4), "marker")
        XCTAssertEqual(WorkoutDetailMapping.eventTypeName(rawValue: 5), "motion_paused")
        XCTAssertEqual(WorkoutDetailMapping.eventTypeName(rawValue: 6), "motion_resumed")
        XCTAssertEqual(WorkoutDetailMapping.eventTypeName(rawValue: 7), "segment")
        XCTAssertEqual(WorkoutDetailMapping.eventTypeName(rawValue: 8), "pause_or_resume_request")
        // A future native case must keep its raw value, not collapse into an existing one.
        XCTAssertEqual(WorkoutDetailMapping.eventTypeName(rawValue: 99), "unknown_99")
    }

    func testAvailabilityNeverReportsPermissionOutcome() {
        // Apple makes denial indistinguishable from absence, so an empty family is
        // reported as not_available_or_not_authorized and never as a denial.
        XCTAssertEqual(WorkoutDetailMapping.availability(isReadable: true, count: 0), .notAvailableOrNotAuthorized)
        XCTAssertEqual(WorkoutDetailMapping.availability(isReadable: true, count: 5), .available)
        XCTAssertEqual(WorkoutDetailMapping.availability(isReadable: true, count: 5, isComplete: false), .partial)
        XCTAssertEqual(WorkoutDetailMapping.availability(isReadable: false, count: 0), .invalid)

        let states = Set(WorkoutDetailAvailability.allCases.map { $0.rawValue })
        XCTAssertEqual(states, [
            "available", "partial", "pending_enrichment",
            "not_available_or_not_authorized", "invalid"
        ])
        XCTAssertFalse(states.contains("permission_denied"))
    }

    func testSourceKeySeparatesDistinctRecorders() {
        let watch = WorkoutDetailMapping.sourceKey(bundleIdentifier: "com.apple.health", productType: "Watch6,18", deviceModel: "Watch")
        let strap = WorkoutDetailMapping.sourceKey(bundleIdentifier: "com.apple.health", productType: nil, deviceModel: "HRM-Pro")
        XCTAssertNotEqual(watch, strap, "a watch and a chest strap must never merge into one stream")
    }
}
