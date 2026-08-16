import XCTest
@testable import OpenWearablesHealthSDK

/// The redaction guard and the probe report's safety.
///
/// The synthetic detail deliberately contains real-looking coordinates, UUIDs, a
/// bundle identifier, a device name, and a specific absolute date. These tests prove
/// none of them can reach a fixture or a report — and, just as importantly, that the
/// guard notices when redaction is broken.
final class WorkoutDetailRedactionTests: XCTestCase {

    private let key = "phase0-test-key"

    // MARK: - Guard passes on a correctly redacted fixture

    func testGuardPassesOnRedactedFixture() throws {
        let detail = WorkoutDetailTestFixtures.detail()
        let data = try WorkoutDetailFixtureWriter.makeFixtureData(from: detail, key: key)

        let report = RedactionGuard.inspect(original: detail, fixtureData: data)
        XCTAssertTrue(report.isClean, report.summary)
        XCTAssertNoThrow(try RedactionGuard.verify(original: detail, fixtureData: data))
        // The guard must actually have had something to look for.
        XCTAssertGreaterThan(report.checkedNeedleCount, 30)
    }

    func testKnownIdentifyingValuesAreAbsentFromFixtureBytes() throws {
        let detail = WorkoutDetailTestFixtures.detail()
        let data = try WorkoutDetailFixtureWriter.makeFixtureData(from: detail, key: key)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        let forbidden = [
            WorkoutDetailTestFixtures.workoutUUID,
            WorkoutDetailTestFixtures.routeUUID,
            WorkoutDetailTestFixtures.sampleUUID,
            WorkoutDetailTestFixtures.activityUUID,
            WorkoutDetailTestFixtures.syncIdentifier,
            WorkoutDetailTestFixtures.externalUUID,
            WorkoutDetailTestFixtures.sourceBundleIdentifier,
            WorkoutDetailTestFixtures.sourceName,
            WorkoutDetailTestFixtures.deviceName,
            WorkoutDetailTestFixtures.deviceManufacturer,
            WorkoutDetailTestFixtures.deviceModel,
            WorkoutDetailTestFixtures.timeZoneIdentifier,
            "51.507351",
            "-0.127758",
            WorkoutDetailTestFixtures.workoutStartDay,
            WorkoutDetailTestFixtures.workoutStartISO,
            "Alexs tempo block"
        ]
        for value in forbidden {
            XCTAssertFalse(text.contains(value), "fixture leaked a forbidden value (category check)")
        }
    }

    // MARK: - Guard fails when redaction is broken

    func testGuardFailsWhenCoordinateRedactionIsBroken() throws {
        let detail = WorkoutDetailTestFixtures.detail()
        var fixture = WorkoutDetailFixtureWriter.makeFixture(from: detail, key: key)

        // Simulate a writer that forgot to translate: put a real coordinate back.
        var route = try XCTUnwrap(fixture["route"] as? [String: Any])
        var parts = try XCTUnwrap(route["parts"] as? [[String: Any]])
        var points = try XCTUnwrap(parts[0]["points"] as? [[String: Any]])
        points[1]["latitude"] = WorkoutDetailTestFixtures.originLatitude + 0.000_1
        parts[0]["points"] = points
        route["parts"] = parts
        fixture["route"] = route

        let data = try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys])
        let report = RedactionGuard.inspect(original: detail, fixtureData: data)

        XCTAssertFalse(report.isClean)
        XCTAssertTrue(report.violations.contains { $0.category == .coordinate })
        XCTAssertThrowsError(try RedactionGuard.verify(original: detail, fixtureData: data))
    }

    func testGuardFailsWhenUUIDRedactionIsBroken() throws {
        let detail = WorkoutDetailTestFixtures.detail()
        var fixture = WorkoutDetailFixtureWriter.makeFixture(from: detail, key: key)

        var identity = try XCTUnwrap(fixture["identity"] as? [String: Any])
        identity["workout_uuid"] = WorkoutDetailTestFixtures.workoutUUID
        fixture["identity"] = identity

        let data = try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys])
        let report = RedactionGuard.inspect(original: detail, fixtureData: data)

        XCTAssertFalse(report.isClean)
        XCTAssertTrue(report.violations.contains { $0.category == .uuid })
    }

    func testGuardFailsWhenTimestampRedactionIsBroken() throws {
        let detail = WorkoutDetailTestFixtures.detail()
        var fixture = WorkoutDetailFixtureWriter.makeFixture(from: detail, key: key)

        var identity = try XCTUnwrap(fixture["identity"] as? [String: Any])
        // A writer that forgot to rebase would emit the real absolute start.
        identity["start_date"] = WorkoutDetailTestFixtures.workoutStartISO
        fixture["identity"] = identity

        let data = try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys])
        let report = RedactionGuard.inspect(original: detail, fixtureData: data)

        XCTAssertFalse(report.isClean)
        XCTAssertTrue(report.violations.contains { $0.category == .absoluteTimestamp })
    }

    func testGuardFailsWhenSourceOrDeviceRedactionIsBroken() throws {
        let detail = WorkoutDetailTestFixtures.detail()
        var fixture = WorkoutDetailFixtureWriter.makeFixture(from: detail, key: key)

        var identity = try XCTUnwrap(fixture["identity"] as? [String: Any])
        identity["source_bundle_id"] = WorkoutDetailTestFixtures.sourceBundleIdentifier
        identity["device_name"] = WorkoutDetailTestFixtures.deviceName
        fixture["identity"] = identity

        let data = try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys])
        let report = RedactionGuard.inspect(original: detail, fixtureData: data)

        XCTAssertFalse(report.isClean)
        XCTAssertTrue(report.violations.contains { $0.category == .sourceIdentifier })
        XCTAssertTrue(report.violations.contains { $0.category == .deviceIdentifier })
    }

    func testGuardFailsWhenTimeZoneSurvives() throws {
        let detail = WorkoutDetailTestFixtures.detail()
        var fixture = WorkoutDetailFixtureWriter.makeFixture(from: detail, key: key)

        var identity = try XCTUnwrap(fixture["identity"] as? [String: Any])
        // A zone identifier narrows down where the workout happened.
        identity["time_zone"] = WorkoutDetailTestFixtures.timeZoneIdentifier
        fixture["identity"] = identity

        let data = try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys])
        XCTAssertTrue(
            RedactionGuard.inspect(original: detail, fixtureData: data)
                .violations.contains { $0.category == .timeZoneIdentifier }
        )
    }

    func testGuardCatchesLeakageAnywhereInTheBytesNotJustKnownFields() throws {
        let detail = WorkoutDetailTestFixtures.detail()
        var fixture = WorkoutDetailFixtureWriter.makeFixture(from: detail, key: key)

        // Hidden in an unexpected place: a nested note nobody thought to check.
        fixture["debug_note"] = "captured at \(WorkoutDetailTestFixtures.sourceBundleIdentifier)"

        let data = try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys])
        XCTAssertFalse(RedactionGuard.inspect(original: detail, fixtureData: data).isClean)
    }

    // MARK: - The guard's own output must be safe

    func testViolationsNeverContainTheLeakedValue() throws {
        let detail = WorkoutDetailTestFixtures.detail()
        var fixture = WorkoutDetailFixtureWriter.makeFixture(from: detail, key: key)
        var identity = try XCTUnwrap(fixture["identity"] as? [String: Any])
        identity["workout_uuid"] = WorkoutDetailTestFixtures.workoutUUID
        identity["device_name"] = WorkoutDetailTestFixtures.deviceName
        fixture["identity"] = identity

        let data = try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys])
        let report = RedactionGuard.inspect(original: detail, fixtureData: data)
        XCTAssertFalse(report.isClean)

        // An error message that quotes the value it caught would itself be a leak.
        let rendered = report.summary + report.violations.map { $0.description }.joined()
        XCTAssertFalse(rendered.contains(WorkoutDetailTestFixtures.workoutUUID))
        XCTAssertFalse(rendered.contains(WorkoutDetailTestFixtures.deviceName))
        XCTAssertFalse(rendered.contains("51.507351"))
    }

    func testShortValuesAreSkippedRatherThanMatchedByCoincidence() {
        var detail = WorkoutDetailTestFixtures.detail()
        detail.identity.deviceManufacturer = "HK"

        let report = RedactionGuard.inspect(original: detail, fixtureData: Data("{}".utf8))
        XCTAssertGreaterThan(report.skippedShortNeedleCount, 0)
    }

    func testScannerFindsNeedlesAtEveryPosition() {
        // Boundary check on the rolling-hash sweep: start, middle, and end.
        let haystack = [UInt8]("ALPHA__MIDDLE__OMEGA".utf8)
        let needles = [
            RedactionGuard.Needle(category: .uuid, location: "start", value: "ALPHA_"),
            RedactionGuard.Needle(category: .uuid, location: "middle", value: "MIDDLE"),
            RedactionGuard.Needle(category: .uuid, location: "end", value: "_OMEGA"),
            RedactionGuard.Needle(category: .uuid, location: "absent", value: "ZULU__")
        ]
        let found = Set(RedactionGuard.scan(needles: needles, in: haystack).map { $0.location })
        XCTAssertEqual(found, ["start", "middle", "end"])
    }

    // MARK: - Probe report safety

    func testProbeReportContainsNoForbiddenContent() {
        let detail = WorkoutDetailTestFixtures.detail()
        let text = WorkoutDetailProbe.makeReport(for: detail).text

        let forbidden = [
            WorkoutDetailTestFixtures.workoutUUID,
            WorkoutDetailTestFixtures.routeUUID,
            WorkoutDetailTestFixtures.sampleUUID,
            WorkoutDetailTestFixtures.activityUUID,
            WorkoutDetailTestFixtures.syncIdentifier,
            WorkoutDetailTestFixtures.externalUUID,
            WorkoutDetailTestFixtures.sourceBundleIdentifier,
            WorkoutDetailTestFixtures.sourceName,
            WorkoutDetailTestFixtures.sourceVersion,
            WorkoutDetailTestFixtures.productType,
            WorkoutDetailTestFixtures.deviceName,
            WorkoutDetailTestFixtures.deviceManufacturer,
            WorkoutDetailTestFixtures.deviceModel,
            WorkoutDetailTestFixtures.timeZoneIdentifier,
            "51.507351", "51.50735", "-0.127758", "-0.12776",
            WorkoutDetailTestFixtures.workoutStartDay,
            WorkoutDetailTestFixtures.workoutStartISO,
            "142", "128", "148.2", "176",   // sample values and statistics
            "Alexs tempo block", "warmup"
        ]
        for value in forbidden {
            XCTAssertFalse(text.contains(value), "probe report leaked forbidden content")
        }
    }

    func testProbeReportStillCarriesTheDiagnosticFacts() {
        let detail = WorkoutDetailTestFixtures.detail()
        let report = WorkoutDetailProbe.makeReport(for: detail)
        let text = report.text

        // Counts, native types, availability, and hash prefixes are the point.
        XCTAssertTrue(text.contains("running"))
        XCTAssertTrue(text.contains("route"))
        XCTAssertTrue(text.contains("heart_rate"))
        XCTAssertTrue(text.contains("available"))
        XCTAssertTrue(text.contains("lap"))
        XCTAssertTrue(text.contains("segment"))
        XCTAssertTrue(text.contains("interval"))
        XCTAssertTrue(text.contains("route_parts=2"))
        XCTAssertTrue(text.contains("top_level_samples=4"))
        XCTAssertTrue(text.contains("expanded_from_series=1"))
        XCTAssertTrue(text.contains("distinct_sources=2"))
        // lap, pause, and resume are all zero-duration in the fixture.
        XCTAssertTrue(text.contains("zero_duration=3"))
        // Presence is reported without the value.
        XCTAssertTrue(text.contains("sync_id=yes"))
        XCTAssertTrue(text.contains("device=yes"))

        XCTAssertEqual(report.family(.route)?.count, 12)
        XCTAssertEqual(report.family(.heartRate)?.count, 5)
        XCTAssertEqual(report.family(.events)?.count, 5)
        XCTAssertEqual(report.family(.activities)?.count, 1)
    }

    func testProbeReportHashPrefixesAreShortAndMatchTheFamilyHashes() throws {
        let detail = WorkoutDetailTestFixtures.detail()
        let report = WorkoutDetailProbe.makeReport(for: detail)
        let hashes = WorkoutDetailHashing.hashes(for: detail)

        for family in WorkoutDetailFamily.allCases {
            let prefix = try XCTUnwrap(report.family(family)?.hashPrefix)
            XCTAssertEqual(prefix.count, 8, "log prefixes must stay short and non-reversible")
            XCTAssertEqual(prefix, String(hashes.hash(for: family).prefix(8)))
        }
        XCTAssertEqual(report.rootHashPrefix.count, 8)
    }

    func testProbeReportBoundsAreElapsedOffsetsNotAbsoluteTimes() {
        let report = WorkoutDetailProbe.makeReport(for: WorkoutDetailTestFixtures.detail())
        let route = report.family(.route)

        // Offsets are relative to the workout start, so they reveal nothing about when.
        XCTAssertEqual(route?.firstElapsedOffset, 0)
        XCTAssertEqual(route?.lastElapsedOffset, 340)
        XCTAssertFalse(report.text.contains("1786778100"))
    }

    func testAdversarialIdentifiersHiddenInIdentityDoNotEscape() {
        // A hostile or careless source could stuff an identifier into identity fields.
        // The report must never reach for identity, source, or device strings.
        var detail = WorkoutDetailTestFixtures.detail()
        detail.identity.sourceName = "com.evil.tracker/user-42"
        detail.identity.deviceName = "Bobs iPhone 15 Pro"
        detail.identity.workoutUUID = "DEADBEEF-0000-4000-8000-00000000FFFF"

        let text = WorkoutDetailProbe.makeReport(for: detail).text
        XCTAssertFalse(text.contains("com.evil.tracker/user-42"))
        XCTAssertFalse(text.contains("Bobs iPhone 15 Pro"))
        XCTAssertFalse(text.contains("DEADBEEF"))
    }

    func testDurationLabelsAreDurationsNotTimestamps() {
        XCTAssertEqual(WorkoutDetailProbe.durationLabel(2533), "42:13")
        XCTAssertEqual(WorkoutDetailProbe.durationLabel(3764), "1:02:44")
        XCTAssertEqual(WorkoutDetailProbe.durationLabel(0), "0:00")
        XCTAssertEqual(WorkoutDetailProbe.relativeLabel(0), "today")
        XCTAssertEqual(WorkoutDetailProbe.relativeLabel(1), "yesterday")
        XCTAssertEqual(WorkoutDetailProbe.relativeLabel(3), "3 days ago")
    }

    func testWorkoutSummaryLabelCarriesNoIdentifier() {
        let summary = WorkoutDetailProbe.WorkoutSummary(
            id: UUID(uuidString: "A1B2C3D4-0000-4000-8000-000000000001")!,
            activityTypeName: "running",
            durationSeconds: 2533,
            daysAgo: 3
        )
        XCTAssertEqual(summary.label, "running — 42:13 — 3 days ago")
        XCTAssertFalse(summary.label.contains("A1B2C3D4"))
    }
}
