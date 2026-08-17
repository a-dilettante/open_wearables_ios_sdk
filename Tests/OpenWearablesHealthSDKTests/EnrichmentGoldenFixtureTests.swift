import XCTest
@testable import OpenWearablesHealthSDK

/// Generates — and pins — the cross-repo golden fixture.
///
/// The device and the server were built against one wire contract but implement the
/// content-hash recipes independently, so "we both read the same spec" is not evidence that
/// they agree. This test runs the real preparation → manifest → outbox pipeline over a
/// deterministic synthetic workout and commits the exact bytes it produces. The same bytes
/// are committed in the open-wearables backend, where
/// `tests/api/v1/test_workout_detail_golden_conformance.py` replays them through the live
/// endpoints and recomputes every family hash from what arrived.
///
/// Committing a generator instead of bytes would prove nothing: both sides would drift
/// together. Committing bytes means a recipe change on either side fails a test on both.
///
/// Nothing here touches HealthKit or the network, and every value is invented.
final class EnrichmentGoldenFixtureTests: XCTestCase {

    /// Set `OW_REGENERATE_GOLDEN=1` to accept new bytes after a deliberate contract change.
    private static let regenerateKey = "OW_REGENERATE_GOLDEN"

    /// The committed fixture directory, resolved from this file rather than from the test
    /// bundle: the bundle holds a build-time copy, and regenerating has to update the copy
    /// that is under version control.
    private static var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("GoldenFixtures", isDirectory: true)
    }

    private var isRegenerating: Bool {
        ProcessInfo.processInfo.environment[Self.regenerateKey] == "1"
    }

    private var outboxDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        outboxDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("golden-outbox-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: outboxDirectory)
        outboxDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - Pipeline

    private struct StagedFixture {
        var staged: StagedEnrichmentUpload
        var manifest: Data
        var manifestObject: [String: Any]
        var chunks: [(record: EnrichmentChunkRecord, bytes: Data)]
    }

    /// Runs the production pipeline end to end and reads back what it wrote.
    private func stageGolden(into directory: URL) throws -> StagedFixture {
        let prepared = EnrichmentPreparation.prepare(GoldenWorkout.detail())
        XCTAssertEqual(prepared.droppedForeignSourceEntryCount, 0, "the fixture must survive preparation intact")
        XCTAssertEqual(prepared.droppedUnmappableEventCount, 0, "every fixture event must be expressible on the wire")

        let outbox = EnrichmentOutbox(directory: directory)
        let staged = try outbox.stage(
            detail: prepared.detail,
            routeAvailability: EnrichmentPreparation.routeAvailability(
                prepared.detail.route,
                workoutEnd: prepared.detail.identity.endDate,
                now: GoldenWorkout.stagedAt
            ),
            now: GoldenWorkout.stagedAt
        )

        let manifest = try Data(contentsOf: outbox.manifestURL(staged.uploadID))
        let manifestObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: manifest) as? [String: Any])

        let chunks = try staged.index.chunks
            .sorted { ($0.family, $0.chunkIndex) < ($1.family, $1.chunkIndex) }
            .map { record in
                (record, try Data(contentsOf: staged.directory.appendingPathComponent(record.fileName)))
            }

        return StagedFixture(staged: staged, manifest: manifest, manifestObject: manifestObject, chunks: chunks)
    }

    // MARK: - The fixture itself

    func testGoldenFixtureMatchesTheCommittedBytes() throws {
        let fixture = try stageGolden(into: outboxDirectory)

        try FileManager.default.createDirectory(at: Self.fixtureDirectory, withIntermediateDirectories: true)
        try pin(fixture.manifest, as: "manifest.json")
        for (record, bytes) in fixture.chunks {
            try pin(bytes, as: record.fileName)
        }
        try pin(expectations(for: fixture), as: "expectations.json")

        // Nothing but the fixture files and the README may live here, or the backend copy
        // would silently diverge from what this test believes it published.
        let present = Set(try FileManager.default.contentsOfDirectory(atPath: Self.fixtureDirectory.path))
        var expected: Set<String> = ["README.md", "manifest.json", "expectations.json"]
        expected.formUnion(fixture.chunks.map { $0.record.fileName })
        XCTAssertEqual(present, expected, "stale files in the fixture directory must be deleted, not left behind")
    }

    /// The whole premise of the fixture: staging the same workout twice produces the same
    /// upload id and byte-identical bodies.
    func testStagingIsByteStableAcrossRuns() throws {
        let first = try stageGolden(into: outboxDirectory)

        let secondDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("golden-outbox-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: secondDirectory) }
        let second = try stageGolden(into: secondDirectory)

        XCTAssertEqual(second.staged.uploadID, first.staged.uploadID)
        XCTAssertEqual(second.staged.rootHash, first.staged.rootHash)
        XCTAssertEqual(second.staged.familyHashes, first.staged.familyHashes)
        XCTAssertEqual(second.manifest, first.manifest, "manifest bytes must be reproducible")
        XCTAssertEqual(second.chunks.map { $0.record.checksum }, first.chunks.map { $0.record.checksum })
        XCTAssertEqual(second.chunks.map { $0.bytes }, first.chunks.map { $0.bytes }, "chunk bytes must be reproducible")
        XCTAssertEqual(try expectations(for: second), try expectations(for: first))
    }

    // MARK: - What the server will recompute

    /// Every declared family hash must be reproducible from the chunk checksums alone —
    /// which is exactly what the server does at completion, so a failure here is an upload
    /// the server would reject as `family_hash_mismatch`.
    func testDeclaredHashesAreDerivedFromTheWireBytes() throws {
        let fixture = try stageGolden(into: outboxDirectory)
        let families = try XCTUnwrap(fixture.manifestObject["families"] as? [String: Any])
        let index = fixture.staged.index

        // Route: per part, then the family over the parts.
        let route = try XCTUnwrap(families["route"] as? [String: Any])
        let parts = try XCTUnwrap(route["parts"] as? [[String: Any]])
        var partHashes: [Int: String] = [:]

        for part in parts {
            let partIndex = try XCTUnwrap(part["part_index"] as? Int)
            let checksums = index.chunks
                .filter { $0.family == "route" && $0.partIndex == partIndex }
                .sorted { $0.chunkIndex < $1.chunkIndex }
                .map { $0.checksum }
            let recomputed = EnrichmentContentHash.routePart(
                partIndex: partIndex,
                pointCount: try XCTUnwrap(part["point_count"] as? Int),
                chunkChecksums: checksums
            )
            XCTAssertEqual(part["content_hash"] as? String, recomputed, "route part \(partIndex)")
            partHashes[partIndex] = recomputed
        }

        XCTAssertEqual(
            route["content_hash"] as? String,
            EnrichmentContentHash.routeFamily(
                pointCount: try XCTUnwrap(route["point_count"] as? Int),
                partHashes: partHashes
            )
        )

        // Heart rate: metric, source key, point count, chunk checksums in index order.
        let heartRate = try XCTUnwrap(families["heart_rate"] as? [String: Any])
        XCTAssertEqual(
            heartRate["content_hash"] as? String,
            EnrichmentContentHash.streamFamily(
                metric: "heart_rate",
                sourceKey: try XCTUnwrap(heartRate["source_key"] as? String),
                pointCount: try XCTUnwrap(heartRate["point_count"] as? Int),
                chunkChecksums: index.chunks
                    .filter { $0.family == "heart_rate" }
                    .sorted { $0.chunkIndex < $1.chunkIndex }
                    .map { $0.checksum }
            )
        )

        // Inline families: the entry ids exactly as they are sent.
        let events = try XCTUnwrap(families["events"] as? [String: Any])
        let eventEntries = try XCTUnwrap(events["entries"] as? [[String: Any]])
        XCTAssertEqual(
            events["content_hash"] as? String,
            EnrichmentContentHash.eventsFamily(contentIDs: eventEntries.compactMap { $0["content_id"] as? String })
        )

        let activities = try XCTUnwrap(families["activities"] as? [String: Any])
        let activityEntries = try XCTUnwrap(activities["entries"] as? [[String: Any]])
        XCTAssertEqual(
            activities["content_hash"] as? String,
            EnrichmentContentHash.activitiesFamily(
                contentHashes: activityEntries.compactMap { $0["content_hash"] as? String }
            )
        )

        // The root covers the declared families and nothing else, which is what makes a
        // replay of unchanged content publish as a no-op instead of a new generation.
        XCTAssertEqual(Set(fixture.staged.familyHashes.keys), Set(families.keys))
        XCTAssertEqual(fixture.staged.rootHash, EnrichmentContentHash.root(familyHashes: fixture.staged.familyHashes))
        XCTAssertEqual(
            fixture.staged.uploadID,
            EnrichmentUploadID.derive(identityKey: index.identityKey, rootContentHash: fixture.staged.rootHash)
        )
    }

    /// The fixture has to be rich enough to be worth pinning and has to stay inside every
    /// limit the server enforces — otherwise the conformance test would fail for reasons
    /// that have nothing to do with hash drift.
    func testFixtureIsRichAndWithinContractLimits() throws {
        let fixture = try stageGolden(into: outboxDirectory)
        let families = try XCTUnwrap(fixture.manifestObject["families"] as? [String: Any])

        let route = try XCTUnwrap(families["route"] as? [String: Any])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(route["point_count"] as? Int), 1_200)
        XCTAssertEqual((route["parts"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(route["gap_count"] as? Int, 1, "two route objects declare exactly one discontinuity")

        let heartRate = try XCTUnwrap(families["heart_rate"] as? [String: Any])
        XCTAssertEqual(heartRate["axis"] as? String, "interval", "the fixture must carry coalesced intervals")
        XCTAssertEqual(heartRate["unit"] as? String, "count/min")
        XCTAssertFalse(try XCTUnwrap(heartRate["gaps"] as? [[String: Any]]).isEmpty, "a declared pause must survive")

        let entries = try XCTUnwrap((families["events"] as? [String: Any])?["entries"] as? [[String: Any]])
        XCTAssertEqual(Set(entries.compactMap { $0["event_type"] as? String }), ["lap", "segment", "pause", "resume"])
        // The legacy zero-duration lap keeps its zero duration rather than being widened.
        let laps = entries.filter { $0["event_type"] as? String == "lap" }
        XCTAssertEqual(laps.filter { $0["end_elapsed_us"] is NSNull }.count, 1)

        XCTAssertEqual(((families["activities"] as? [String: Any])?["entries"] as? [[String: Any]])?.count, 2)

        for (record, bytes) in fixture.chunks {
            XCTAssertLessThanOrEqual(record.pointCount, EnrichmentWire.maximumPointsPerChunk)
            XCTAssertLessThanOrEqual(bytes.count, EnrichmentWire.maximumCompressedChunkBytes)
            // The server refuses anything that inflates past 20x, as an anti-bomb control.
            // Synthetic data compresses far better than real data, so for a fixture this is
            // a real risk and is asserted rather than assumed.
            XCTAssertLessThan(
                Double(record.uncompressedBytes) / Double(bytes.count),
                20,
                "\(record.fileName) inflates past the server's decompression ratio ceiling"
            )
        }
    }

    // MARK: - Expectations file

    private func expectations(for fixture: StagedFixture) throws -> Data {
        let families = try XCTUnwrap(fixture.manifestObject["families"] as? [String: Any])
        let route = try XCTUnwrap(families["route"] as? [String: Any])
        let heartRate = try XCTUnwrap(families["heart_rate"] as? [String: Any])

        let payload: [String: Any] = [
            "schema_version": EnrichmentWire.schemaVersion,
            "upload_id": fixture.staged.uploadID,
            "identity_key": fixture.staged.index.identityKey,
            "root_hash": fixture.staged.rootHash,
            "manifest_sha256": WorkoutDetailHashing.sha256Hex(fixture.manifest),
            "family_hashes": fixture.staged.familyHashes,
            "route": [
                "point_count": try XCTUnwrap(route["point_count"] as? Int),
                "chunk_count": try XCTUnwrap(route["chunk_count"] as? Int),
                "parts": try XCTUnwrap(route["parts"] as? [[String: Any]]).map { part in
                    [
                        "part_index": part["part_index"] as? Int ?? -1,
                        "point_count": part["point_count"] as? Int ?? -1,
                        "content_hash": part["content_hash"] as? String ?? ""
                    ]
                }
            ],
            "heart_rate": [
                "point_count": try XCTUnwrap(heartRate["point_count"] as? Int),
                "chunk_count": try XCTUnwrap(heartRate["chunk_count"] as? Int),
                "axis": try XCTUnwrap(heartRate["axis"] as? String)
            ],
            "chunks": fixture.chunks.map { record, bytes in
                [
                    "family": record.family,
                    "chunk_index": record.chunkIndex,
                    "part_index": record.partIndex as Any? ?? NSNull(),
                    "file_name": record.fileName,
                    "checksum": record.checksum,
                    "uncompressed_bytes": record.uncompressedBytes,
                    "compressed_bytes": bytes.count,
                    "point_count": record.pointCount
                ]
            }
        ]

        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
    }

    // MARK: - Pinning

    /// Writes `data` to the committed fixture, or fails if what is committed differs.
    ///
    /// Overwriting on mismatch would make this test self-healing and therefore useless as a
    /// tripwire, so a difference is reported and the committed bytes are left alone unless
    /// regeneration was asked for explicitly.
    private func pin(_ data: Data, as name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let url = Self.fixtureDirectory.appendingPathComponent(name)

        if !isRegenerating, let committed = try? Data(contentsOf: url), committed != data {
            XCTFail(
                """
                Golden fixture \(name) no longer matches what the pipeline produces. If the wire \
                contract or a hash recipe changed on purpose, regenerate with \(Self.regenerateKey)=1 \
                and copy the new bytes to the open-wearables backend at \
                backend/tests/fixtures/workout_owned_detail_golden/. If it did not change on purpose, \
                this is the drift the fixture exists to catch.
                """,
                file: file,
                line: line
            )
            return
        }

        try data.write(to: url, options: .atomic)
    }
}

// MARK: - The synthetic workout

/// A deterministic workout, shaped like the awkward cases the contract has to survive: a
/// route delivered as two `HKWorkoutRoute` objects with a real hole between them, a heart
/// rate stream mixing instant readings with coalesced intervals expanded from a condensed
/// series, laps that abut without overlapping beside a legacy zero-duration lap marker,
/// segments that deliberately overlap each other, a pause/resume pair, and two activities.
///
/// Every number comes from a fixed seed, so the bytes are reproducible on any machine.
/// Coordinates carry pseudo-random jitter because perfectly regular values compress past
/// the server's anti-bomb ratio ceiling and would fail for the wrong reason.
enum GoldenWorkout {

    /// 2026-01-02T03:04:05Z. UTC on purpose: the manifest then carries `Z`-suffixed
    /// timestamps, which is the form the server has to parse.
    static let start = Date(timeIntervalSince1970: 1_767_323_045)
    static let duration: TimeInterval = 1_800
    static var end: Date { start.addingTimeInterval(duration) }

    /// Fixed staging clock, so nothing in the fixture depends on when it was generated.
    static let stagedAt = Date(timeIntervalSince1970: 1_767_326_000)

    static let workoutUUID = "00000000-0000-4000-8000-00000000ff01"
    static let firstRouteUUID = "00000000-0000-4000-8000-00000000ff02"
    static let secondRouteUUID = "00000000-0000-4000-8000-00000000ff03"
    static let syncIdentifier = "golden-sync-0001"
    static let bundleIdentifier = "com.example.goldenrecorder"
    static let sourceKey = "com.example.goldenrecorder|Watch7,1|Golden Watch"

    static let firstPartPointCount = 820
    static let secondPartPointCount = 460
    static let heartRateEntryCount = 600

    /// A 64-bit LCG. Reproducible everywhere: the arithmetic is exact in `UInt64` and the
    /// division into `[0, 1)` is a correctly-rounded IEEE operation.
    private struct Noise {
        private var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func unit() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
    }

    static func detail() -> CollectedWorkoutDetail {
        CollectedWorkoutDetail(
            identity: identity(),
            route: route(),
            heartRate: heartRate(),
            events: events(),
            activities: activities()
        )
    }

    static func identity() -> WorkoutIdentity {
        WorkoutIdentity(
            workoutUUID: workoutUUID,
            syncIdentifier: syncIdentifier,
            syncVersion: 1,
            externalUUID: nil,
            sourceBundleIdentifier: bundleIdentifier,
            sourceName: "Golden Recorder",
            sourceVersion: "1.0.0",
            sourceProductType: "Watch7,1",
            deviceManufacturer: "Example Inc.",
            deviceModel: "Golden Watch",
            timeZoneIdentifier: "UTC",
            timeZoneOffsetSeconds: 0,
            activityTypeRawValue: 37,
            activityTypeName: "running",
            startDate: start,
            endDate: end,
            // Wall clock minus the declared 60-second pause.
            duration: duration - 60
        )
    }

    // MARK: Route

    /// Two route objects: 0…~819s and 1200…~1659s. The hole between them is a
    /// discontinuity the source itself declared by writing two objects, which is the only
    /// kind of gap this contract reports.
    static func route() -> WorkoutRouteDetail {
        WorkoutRouteDetail(
            availability: .available,
            parts: [
                RoutePart(
                    routeUUID: firstRouteUUID,
                    partIndex: 0,
                    batchCount: 3,
                    points: points(count: firstPartPointCount, startOffset: 0, seed: 0x5EED_0001, indexBase: 0)
                ),
                RoutePart(
                    routeUUID: secondRouteUUID,
                    partIndex: 1,
                    batchCount: 2,
                    points: points(
                        count: secondPartPointCount,
                        startOffset: 1_200,
                        seed: 0x5EED_0002,
                        indexBase: firstPartPointCount
                    )
                )
            ]
        )
    }

    private static func points(count: Int, startOffset: TimeInterval, seed: UInt64, indexBase: Int) -> [RoutePoint] {
        var noise = Noise(seed: seed)

        return (0..<count).map { index in
            // Roughly one sample per second, irregularly spaced: HealthKit publishes no
            // cadence guarantee and nothing downstream may assume one.
            let offset = startOffset + Double(index) + Double(index % 7) * 0.05
            let walked = Double(indexBase + index)

            return RoutePoint(
                timestamp: start.addingTimeInterval(offset),
                elapsedOffset: offset,
                latitude: 45.0 + walked * 0.000_07 + noise.unit() * 0.000_01,
                longitude: 9.0 + walked * 0.000_11 + noise.unit() * 0.000_01,
                // A channel the source did not measure is null, never zero.
                altitude: index % 11 == 0 ? nil : 100 + noise.unit() * 40,
                // CoreLocation reports an unusable speed as a negative sentinel; the reader
                // maps those to nil rather than shipping a number that reads as real.
                speed: index % 17 == 0 ? nil : 2.4 + noise.unit() * 2.0,
                course: noise.unit() * 359.0,
                horizontalAccuracy: 3.0 + noise.unit() * 6.0,
                verticalAccuracy: index % 2 == 0 ? 4.0 + noise.unit() * 3.0 : nil,
                ordinal: index
            )
        }
    }

    // MARK: Heart rate

    /// Instant readings interleaved with coalesced intervals. Every third entry covers a
    /// two-second span and is flagged as expanded from a condensed series, which is real
    /// provenance no other column carries.
    static func heartRate() -> WorkoutQuantityStream {
        var noise = Noise(seed: 0x5EED_0003)

        let entries = (0..<heartRateEntryCount).map { index -> QuantityEntry in
            let startOffset = Double(index) * 2.9
            let isInterval = index % 3 == 0
            let endOffset = isInterval ? startOffset + 2.0 : startOffset

            return QuantityEntry(
                startDate: start.addingTimeInterval(startOffset),
                endDate: start.addingTimeInterval(endOffset),
                startElapsedOffset: startOffset,
                endElapsedOffset: endOffset,
                value: (110 + noise.unit() * 70).rounded(),
                unit: "count/min",
                sampleUUID: nil,
                sourceKey: sourceKey,
                kind: isInterval ? .interval : .point,
                isExpandedFromSeries: isInterval,
                parentSeriesCount: isInterval ? 12 : 1,
                // Increases alongside the offsets, so the (elapsed, ordinal) pair the
                // server requires to strictly increase actually does.
                ordinal: index
            )
        }

        return WorkoutQuantityStream(
            availability: .available,
            metric: "heart_rate",
            quantityTypeIdentifier: "HKQuantityTypeIdentifierHeartRate",
            entries: entries,
            // Outer samples, not expanded entries: a condensed series is one HealthKit
            // object however many readings it holds.
            topLevelSampleCount: heartRateEntryCount - (heartRateEntryCount / 3)
        )
    }

    // MARK: Events

    static func events() -> WorkoutEventsDetail {
        func event(
            _ typeRawValue: Int,
            _ typeName: String,
            from startOffset: TimeInterval,
            to endOffset: TimeInterval,
            metadata: [String: String] = [:],
            ordinal: Int
        ) -> WorkoutEventEntry {
            WorkoutEventEntry(
                typeRawValue: typeRawValue,
                typeName: typeName,
                startDate: start.addingTimeInterval(startOffset),
                endDate: start.addingTimeInterval(endOffset),
                startElapsedOffset: startOffset,
                endElapsedOffset: endOffset,
                metadata: metadata,
                ordinal: ordinal
            )
        }

        return WorkoutEventsDetail(availability: .available, events: [
            // Laps abut but never overlap: an end is exclusive, so one closing at 600 and
            // the next opening at 600 is contiguous.
            event(3, "lap", from: 0, to: 600, ordinal: 0),
            event(3, "lap", from: 600, to: 1_200, ordinal: 1),
            // Segments are allowed to overlap each other, and deliberately do.
            event(7, "segment", from: 0, to: 900, metadata: ["HKMetadataKeySegmentLabel": "warmup"], ordinal: 2),
            event(7, "segment", from: 600, to: 1_500, metadata: ["HKMetadataKeySegmentLabel": "tempo"], ordinal: 3),
            // A pause and its resume, which is where the declared stream gap comes from.
            event(1, "pause", from: 1_200, to: 1_200, ordinal: 4),
            event(2, "resume", from: 1_260, to: 1_260, ordinal: 5),
            // A legacy zero-duration lap marker. It keeps its zero duration and is reported
            // with no end rather than widened into a synthetic interval.
            event(3, "lap", from: 1_500, to: 1_500, ordinal: 6)
        ])
    }

    // MARK: Activities

    static func activities() -> WorkoutActivitiesDetail {
        WorkoutActivitiesDetail(
            availability: .available,
            activities: [
                WorkoutActivityEntry(
                    activityUUID: "00000000-0000-4000-8000-00000000fa01",
                    position: 0,
                    activityTypeRawValue: 37,
                    activityTypeName: "running",
                    startDate: start,
                    endDate: start.addingTimeInterval(900),
                    startElapsedOffset: 0,
                    endElapsedOffset: 900,
                    duration: 900,
                    statistics: [
                        ActivityStatistic(
                            quantityTypeIdentifier: "HKQuantityTypeIdentifierHeartRate",
                            aggregation: "average",
                            value: 142.5,
                            unit: "count/min"
                        ),
                        ActivityStatistic(
                            quantityTypeIdentifier: "HKQuantityTypeIdentifierHeartRate",
                            aggregation: "maximum",
                            value: 171,
                            unit: "count/min"
                        )
                    ],
                    metadata: ["HKMetadataKeyIndoorWorkout": "0"]
                ),
                WorkoutActivityEntry(
                    activityUUID: "00000000-0000-4000-8000-00000000fa02",
                    position: 1,
                    activityTypeRawValue: 37,
                    activityTypeName: "running",
                    startDate: start.addingTimeInterval(900),
                    endDate: end,
                    startElapsedOffset: 900,
                    endElapsedOffset: duration,
                    duration: duration - 900 - 60,
                    statistics: [
                        ActivityStatistic(
                            quantityTypeIdentifier: "HKQuantityTypeIdentifierHeartRate",
                            aggregation: "average",
                            value: 156.25,
                            unit: "count/min"
                        )
                    ],
                    metadata: [:]
                )
            ],
            isSupportedOnThisOS: true
        )
    }
}
