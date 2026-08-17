import XCTest
@testable import OpenWearablesHealthSDK

/// Chunk encoding, gzip framing, checksums, and the staged-upload layout.
///
/// All input is synthetic and no HealthKit or network access occurs.
final class EnrichmentOutboxTests: XCTestCase {

    private var directory: URL!
    private var outbox: EnrichmentOutbox!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("enrichment-outbox-\(UUID().uuidString)", isDirectory: true)
        outbox = EnrichmentOutbox(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        outbox = nil
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func preparedDetail() -> CollectedWorkoutDetail {
        EnrichmentPreparation.prepare(WorkoutDetailTestFixtures.detail()).detail
    }

    private func syntheticPoints(_ count: Int) -> [RoutePoint] {
        (0..<count).map { index in
            RoutePoint(
                timestamp: WorkoutDetailTestFixtures.workoutStart.addingTimeInterval(Double(index)),
                elapsedOffset: Double(index),
                latitude: 51.5 + Double(index) * 0.000_01,
                longitude: -0.12 + Double(index) * 0.000_01,
                altitude: 10 + Double(index % 7),
                speed: 3.2,
                course: 88.1,
                horizontalAccuracy: 4,
                verticalAccuracy: 3,
                ordinal: index
            )
        }
    }

    // MARK: - Gzip

    func testGzipRoundTrip() throws {
        for payload in ["", "{}", String(repeating: "route point payload ", count: 5_000)] {
            let data = Data(payload.utf8)
            let compressed = EnrichmentGzip.compress(data)

            XCTAssertEqual(Array(compressed.prefix(3)), [0x1f, 0x8b, 0x08], "must be a gzip member")
            XCTAssertEqual(EnrichmentGzip.decompress(compressed), data)
        }
    }

    /// The gzip header must not carry a modification time, or identical content would
    /// produce different bytes on every run and break replay.
    func testGzipIsDeterministic() {
        let data = Data(String(repeating: "abc", count: 1_000).utf8)
        XCTAssertEqual(EnrichmentGzip.compress(data), EnrichmentGzip.compress(data))
        XCTAssertEqual(Array(EnrichmentGzip.compress(data)[4..<8]), [0, 0, 0, 0], "mtime must be pinned to zero")
    }

    func testGzipRejectsNonGzipInput() {
        XCTAssertNil(EnrichmentGzip.decompress(Data("plain text, not gzip at all".utf8)))
    }

    // MARK: - Chunk splitting

    /// Splitting is bounded by measured serialized size *and* point count. A route point
    /// serializes far wider than a heart-rate entry, so a point-count limit alone would
    /// produce chunks differing by an order of magnitude in bytes.
    func testSplitRespectsPointCountLimit() {
        let points = syntheticPoints(25)
        let ranges = EnrichmentChunkEncoder.split(
            points,
            cost: EnrichmentChunkEncoder.routePointCost,
            targetBytes: .max,
            maximumCount: 10
        )

        XCTAssertEqual(ranges.map { $0.count }, [10, 10, 5])
        XCTAssertEqual(ranges.reduce(0) { $0 + $1.count }, points.count, "no point may be dropped")
    }

    func testSplitRespectsByteBudget() {
        let points = syntheticPoints(100)
        let perPoint = EnrichmentChunkEncoder.routePointCost(points[0])
        let ranges = EnrichmentChunkEncoder.split(
            points,
            cost: EnrichmentChunkEncoder.routePointCost,
            targetBytes: perPoint * 8,
            maximumCount: .max
        )

        XCTAssertGreaterThan(ranges.count, 1)
        for range in ranges {
            let bytes = points[range].reduce(0) { $0 + EnrichmentChunkEncoder.routePointCost($1) }
            XCTAssertLessThanOrEqual(bytes, perPoint * 8)
        }
        XCTAssertEqual(ranges.reduce(0) { $0 + $1.count }, points.count)
    }

    /// A single item wider than the whole budget still gets its own chunk. Silently
    /// truncating it would be data loss.
    func testOversizedSingleItemIsNotDropped() {
        let ranges = EnrichmentChunkEncoder.split(
            syntheticPoints(3),
            cost: { (_: RoutePoint) in 10_000 },
            targetBytes: 10
        )
        XCTAssertEqual(ranges.map { $0.count }, [1, 1, 1])
    }

    func testDefaultLimitsMatchTheContract() {
        XCTAssertEqual(EnrichmentWire.maximumPointsPerChunk, 16_384)
        XCTAssertEqual(EnrichmentWire.targetUncompressedChunkBytes, 1_048_576)
        XCTAssertEqual(EnrichmentWire.maximumCompressedChunkBytes, 4 * 1_048_576)
    }

    // MARK: - Chunk bodies

    func testRouteChunkArraysAreAlignedAndOrdered() throws {
        let part = preparedDetail().route.parts[0]
        // Feed the points in reverse to prove the encoder sorts rather than trusting input.
        let body = EnrichmentChunkEncoder.routeChunkBody(partIndex: 0, points: part.points.reversed())
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(json["schema_version"] as? Int, 1)
        XCTAssertEqual(json["part_index"] as? Int, 0)

        let elapsed = try XCTUnwrap(json["elapsed_us"] as? [Int])
        let latitudes = try XCTUnwrap(json["lat"] as? [Double])
        let longitudes = try XCTUnwrap(json["lng"] as? [Double])
        XCTAssertEqual(elapsed.count, part.points.count)
        XCTAssertEqual(latitudes.count, elapsed.count, "columns must be aligned")
        XCTAssertEqual(longitudes.count, elapsed.count)
        XCTAssertEqual(elapsed, elapsed.sorted(), "elapsed_us must ascend")
        XCTAssertEqual(elapsed[0], 0)

        // Optional columns keep per-point nulls rather than inventing values.
        let verticalAccuracy = try XCTUnwrap(json["v_acc"] as? [Any])
        XCTAssertEqual(verticalAccuracy.count, elapsed.count)
        XCTAssertTrue(verticalAccuracy.contains { $0 is NSNull })

        // No flag is defined for routes, so the column is explicitly null.
        XCTAssertTrue(json["flags"] is NSNull)
    }

    /// A column where every value is absent is `null`, not an array of nulls.
    func testFullyAbsentOptionalColumnIsNull() throws {
        let points = (0..<3).map { index in
            RoutePoint(
                timestamp: WorkoutDetailTestFixtures.workoutStart,
                elapsedOffset: Double(index),
                latitude: 51.5, longitude: -0.12,
                altitude: nil, speed: nil, course: nil,
                horizontalAccuracy: nil, verticalAccuracy: nil,
                ordinal: index
            )
        }
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: EnrichmentChunkEncoder.routeChunkBody(partIndex: 0, points: points)
            ) as? [String: Any]
        )

        for column in ["altitude", "speed", "course", "h_acc", "v_acc"] {
            XCTAssertTrue(json[column] is NSNull, "\(column) must be null when nothing was measured")
        }
    }

    func testStreamChunkPreservesIntervalsAndSeriesProvenance() throws {
        let stream = preparedDetail().heartRate
        let body = EnrichmentChunkEncoder.streamChunkBody(metric: "heart_rate", entries: stream.entries.reversed())
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(json["metric"] as? String, "heart_rate")

        let starts = try XCTUnwrap(json["elapsed_us"] as? [Int])
        let ends = try XCTUnwrap(json["end_elapsed_us"] as? [Int])
        let values = try XCTUnwrap(json["value"] as? [Double])
        let ordinals = try XCTUnwrap(json["ordinal"] as? [Int])
        XCTAssertEqual(starts.count, stream.entries.count)
        XCTAssertEqual(ends.count, starts.count)
        XCTAssertEqual(values.count, starts.count)
        XCTAssertEqual(ordinals.count, starts.count)
        XCTAssertEqual(starts, starts.sorted())

        // The coalesced interval must survive as a span, not collapse to an instant.
        let intervalIndex = try XCTUnwrap(starts.indices.first { starts[$0] != ends[$0] })
        XCTAssertEqual(starts[intervalIndex], 10_000_000)
        XCTAssertEqual(ends[intervalIndex], 25_000_000)

        // `series` records that an entry came from HKQuantitySeriesSampleQuery — real
        // provenance no other column carries.
        let flags = try XCTUnwrap(json["flags"] as? [[String]])
        XCTAssertEqual(flags.count, starts.count)
        XCTAssertEqual(flags[intervalIndex], ["series"])
    }

    /// Equal timestamps are legal; `ordinal` decides the order and neither entry is
    /// dropped or reordered non-deterministically.
    func testEqualTimestampsAreBrokenByOrdinal() throws {
        let entries = (0..<2).map { index in
            QuantityEntry(
                startDate: WorkoutDetailTestFixtures.workoutStart,
                endDate: WorkoutDetailTestFixtures.workoutStart,
                startElapsedOffset: 40, endElapsedOffset: 40,
                value: 150 + Double(index), unit: "count/min",
                sourceKey: "k", kind: .point, ordinal: 1 - index
            )
        }
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: EnrichmentChunkEncoder.streamChunkBody(metric: "heart_rate", entries: entries)
            ) as? [String: Any]
        )

        XCTAssertEqual(try XCTUnwrap(json["ordinal"] as? [Int]), [0, 1])
        XCTAssertEqual(try XCTUnwrap(json["value"] as? [Double]), [151, 150])
    }

    func testChunkBodiesAreByteIdenticalForTheSameInput() {
        let detail = preparedDetail()
        let part = detail.route.parts[0]

        XCTAssertEqual(
            EnrichmentChunkEncoder.routeChunkBody(partIndex: 0, points: part.points),
            EnrichmentChunkEncoder.routeChunkBody(partIndex: 0, points: part.points.reversed())
        )
        XCTAssertEqual(
            EnrichmentChunkEncoder.streamChunkBody(metric: "heart_rate", entries: detail.heartRate.entries),
            EnrichmentChunkEncoder.streamChunkBody(metric: "heart_rate", entries: detail.heartRate.entries.reversed())
        )
    }

    // MARK: - Staging

    func testStageWritesManifestChunksAndIndex() throws {
        let staged = try outbox.stage(detail: preparedDetail(), routeAvailability: .available)
        let files = try FileManager.default.contentsOfDirectory(atPath: staged.directory.path).sorted()

        XCTAssertTrue(files.contains("manifest.json"))
        XCTAssertTrue(files.contains("index.json"))
        // The fixture has two route objects, so both parts appear with global chunk
        // indices and their part identified in the file name.
        XCTAssertTrue(files.contains("route_p0_chunk000.json.gz"))
        XCTAssertTrue(files.contains("route_p1_chunk001.json.gz"))
        XCTAssertTrue(files.contains("heart_rate_chunk000.json.gz"))

        let index = try XCTUnwrap(outbox.loadIndex(uploadID: staged.uploadID))
        XCTAssertEqual(index.uploadID, staged.uploadID)
        XCTAssertFalse(index.isManifestAccepted)
        XCTAssertFalse(index.isCompleteRequested)
        XCTAssertFalse(index.allChunksUploaded)
        XCTAssertEqual(index.pendingChunks.count, index.chunks.count)

        let routeChunks = index.chunks.filter { $0.family == "route" }
        XCTAssertEqual(routeChunks.map { $0.chunkIndex }.sorted(), [0, 1])
        XCTAssertEqual(routeChunks.compactMap { $0.partIndex }.sorted(), [0, 1])
        XCTAssertNil(index.chunks.first { $0.family == "heart_rate" }?.partIndex)
    }

    /// The checksum in the index is the SHA-256 of the *uncompressed* bytes — the value
    /// the server re-derives after inflating.
    func testChunkChecksumsCoverUncompressedBytes() throws {
        let staged = try outbox.stage(detail: preparedDetail(), routeAvailability: .available)
        let index = try XCTUnwrap(outbox.loadIndex(uploadID: staged.uploadID))

        for record in index.chunks {
            let url = staged.directory.appendingPathComponent(record.fileName)
            let compressed = try Data(contentsOf: url)
            let inflated = try XCTUnwrap(EnrichmentGzip.decompress(compressed))

            XCTAssertEqual(record.checksum, WorkoutDetailHashing.sha256Hex(inflated))
            XCTAssertEqual(record.uncompressedBytes, inflated.count)
            XCTAssertEqual(record.compressedBytes, compressed.count)
            XCTAssertLessThanOrEqual(record.pointCount, EnrichmentWire.maximumPointsPerChunk)
            XCTAssertLessThanOrEqual(record.compressedBytes, EnrichmentWire.maximumCompressedChunkBytes)
        }
    }

    func testStagedManifestMatchesTheStagedChunks() throws {
        let staged = try outbox.stage(detail: preparedDetail(), routeAvailability: .available)
        let manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: try Data(contentsOf: outbox.manifestURL(staged.uploadID))
            ) as? [String: Any]
        )
        let families = try XCTUnwrap(manifest["families"] as? [String: Any])
        let index = try XCTUnwrap(outbox.loadIndex(uploadID: staged.uploadID))

        let route = try XCTUnwrap(families["route"] as? [String: Any])
        XCTAssertEqual(route["chunk_count"] as? Int, index.chunks.filter { $0.family == "route" }.count)
        XCTAssertEqual(route["point_count"] as? Int, staged.routePointCount)
        XCTAssertEqual(route["availability"] as? String, "available")

        let bounds = try XCTUnwrap(route["bounds"] as? [String: Double])
        XCTAssertLessThanOrEqual(try XCTUnwrap(bounds["min_lat"]), try XCTUnwrap(bounds["max_lat"]))
        XCTAssertLessThanOrEqual(try XCTUnwrap(bounds["min_lng"]), try XCTUnwrap(bounds["max_lng"]))

        let heartRate = try XCTUnwrap(families["heart_rate"] as? [String: Any])
        XCTAssertEqual(heartRate["chunk_count"] as? Int, index.chunks.filter { $0.family == "heart_rate" }.count)
        XCTAssertEqual(heartRate["point_count"] as? Int, staged.heartRatePointCount)
    }

    /// Replay: the same detail staged twice yields the same upload id, the same hashes,
    /// and byte-identical chunk files.
    func testReplayProducesIdenticalUploadAndBytes() throws {
        let first = try outbox.stage(detail: preparedDetail(), routeAvailability: .available)
        var firstBytes: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: first.directory.path)
        where name.hasSuffix(".json.gz") {
            firstBytes[name] = try Data(contentsOf: first.directory.appendingPathComponent(name))
        }
        XCTAssertFalse(firstBytes.isEmpty)

        let second = try outbox.stage(detail: preparedDetail(), routeAvailability: .available)

        XCTAssertEqual(second.uploadID, first.uploadID)
        XCTAssertEqual(second.rootHash, first.rootHash)
        XCTAssertEqual(second.familyHashes, first.familyHashes)
        for (name, bytes) in firstBytes {
            XCTAssertEqual(
                try Data(contentsOf: second.directory.appendingPathComponent(name)),
                bytes,
                "\(name) must be byte-identical on replay"
            )
        }
    }

    /// Richer content is a different upload, so a late route never overwrites the
    /// staging area of the generation that is still in flight.
    func testRicherContentBecomesADifferentUpload() throws {
        var withoutRoute = preparedDetail()
        withoutRoute.route = WorkoutRouteDetail(availability: .notAvailableOrNotAuthorized)

        let first = try outbox.stage(detail: withoutRoute, routeAvailability: .pendingEnrichment)
        let second = try outbox.stage(detail: preparedDetail(), routeAvailability: .available)

        XCTAssertNotEqual(second.uploadID, first.uploadID)
        XCTAssertNotEqual(second.rootHash, first.rootHash)
        XCTAssertNil(first.familyHashes["route"], "an absent route must not claim a route family hash")
        XCTAssertNotNil(second.familyHashes["route"])
    }

    /// A route that has not arrived yet is *omitted*, never sent as an empty family.
    /// An empty read cannot be distinguished from a denied one, so declaring the family
    /// would invite the server to clear a route it already published.
    func testPendingRouteIsOmittedButStillTrackedInTheIndex() throws {
        var detail = preparedDetail()
        detail.route = WorkoutRouteDetail(availability: .notAvailableOrNotAuthorized)

        let staged = try outbox.stage(detail: detail, routeAvailability: .pendingEnrichment)
        let manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: try Data(contentsOf: outbox.manifestURL(staged.uploadID))
            ) as? [String: Any]
        )

        XCTAssertNil((manifest["families"] as? [String: Any])?["route"])
        XCTAssertTrue((manifest["omitted_families"] as? [String] ?? []).contains("route"))

        // The pending state still has to survive, or late-route reconciliation would
        // never revisit this workout after its receipt arrives.
        XCTAssertEqual(
            outbox.loadIndex(uploadID: staged.uploadID)?.routeAvailability,
            WorkoutDetailAvailability.pendingEnrichment.rawValue
        )
        XCTAssertEqual(staged.routeAvailability, .pendingEnrichment)
    }

    /// A workout with no route still publishes its heart rate, events, and activities.
    func testWorkoutWithoutRouteStillStagesOtherFamilies() throws {
        var detail = preparedDetail()
        detail.route = WorkoutRouteDetail(availability: .notAvailableOrNotAuthorized)

        let staged = try outbox.stage(detail: detail, routeAvailability: .notAvailableOrNotAuthorized)
        let manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: try Data(contentsOf: outbox.manifestURL(staged.uploadID))
            ) as? [String: Any]
        )
        let families = try XCTUnwrap(manifest["families"] as? [String: Any])

        XCTAssertNotNil(families["heart_rate"])
        XCTAssertNotNil(families["events"])
        XCTAssertNotNil(families["activities"])
        // The route is omitted, which tells the server to leave the published family
        // alone rather than clear it.
        XCTAssertNil(families["route"])
        XCTAssertTrue((manifest["omitted_families"] as? [String] ?? []).contains("route"))
        XCTAssertEqual(staged.routePointCount, 0)
    }

    // MARK: - File protection

    func testEveryStagedFileIsExcludedFromBackupAndProtected() throws {
        let staged = try outbox.stage(detail: preparedDetail(), routeAvailability: .available)

        for name in try FileManager.default.contentsOfDirectory(atPath: staged.directory.path) {
            let url = staged.directory.appendingPathComponent(name)
            let excluded = try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
            XCTAssertEqual(excluded, true, "\(name) must never enter a backup")
            XCTAssertTrue(EnrichmentFileProtection.isProtected(url))
        }
    }

    // MARK: - Lifecycle

    func testMarkChunkUploadedAdvancesTheIndex() throws {
        let staged = try outbox.stage(detail: preparedDetail(), routeAvailability: .available)
        let index = try XCTUnwrap(outbox.loadIndex(uploadID: staged.uploadID))

        for record in index.chunks {
            outbox.markChunkUploaded(uploadID: staged.uploadID, fileName: record.fileName)
        }

        let updated = try XCTUnwrap(outbox.loadIndex(uploadID: staged.uploadID))
        XCTAssertTrue(updated.allChunksUploaded)
        XCTAssertTrue(updated.pendingChunks.isEmpty)
    }

    func testRemoveAndUploadIDPrefixLookup() throws {
        let staged = try outbox.stage(detail: preparedDetail(), routeAvailability: .available)
        let prefix = EnrichmentUploadID.logPrefix(staged.uploadID)

        // The background task description carries only this prefix, never an identity.
        XCTAssertEqual(outbox.uploadID(matchingPrefix: prefix), staged.uploadID)

        outbox.remove(uploadID: staged.uploadID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.directory.path))
        XCTAssertNil(outbox.loadIndex(uploadID: staged.uploadID))
    }

    func testExpiryDropsStaleUploadsAndKeepsFreshOnes() throws {
        let stale = try outbox.stage(
            detail: preparedDetail(),
            routeAvailability: .available,
            now: Date().addingTimeInterval(-(EnrichmentOutbox.expiry + 3600))
        )
        var fresh = preparedDetail()
        fresh.heartRate.entries[0].value += 5 // different content, different upload id
        let kept = try outbox.stage(detail: fresh, routeAvailability: .available)

        XCTAssertEqual(outbox.expireStaleUploads(), 1)
        XCTAssertNil(outbox.loadIndex(uploadID: stale.uploadID))
        XCTAssertNotNil(outbox.loadIndex(uploadID: kept.uploadID))
    }

    func testRemoveAllClearsEverything() throws {
        _ = try outbox.stage(detail: preparedDetail(), routeAvailability: .available)
        outbox.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
