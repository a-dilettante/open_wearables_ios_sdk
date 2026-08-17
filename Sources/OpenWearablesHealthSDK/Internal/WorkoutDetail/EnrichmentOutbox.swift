import Foundation

// MARK: - Staged records

/// One staged chunk file, described well enough to upload and validate it without
/// re-reading or re-encoding its contents.
struct EnrichmentChunkRecord: Codable, Equatable {
    var family: String
    /// Index within the family, unique across the whole family.
    ///
    /// Route chunks number globally rather than per part, so the server can prove every
    /// expected chunk arrived from `chunk_count` alone; `partIndex` still identifies
    /// which route object the chunk belongs to and is sent as a query parameter.
    var chunkIndex: Int
    var partIndex: Int?
    var fileName: String
    /// SHA-256 of the **uncompressed** bytes, computed at write time. This is the value
    /// the `X-Chunk-Checksum` header carries and the server re-derives after inflating.
    var checksum: String
    var uncompressedBytes: Int
    var compressedBytes: Int
    var pointCount: Int
    var isUploaded: Bool
}

/// Sidecar index for one staged upload. Survives process death so a resumed run knows
/// exactly which chunks still need sending without re-reading HealthKit.
struct EnrichmentUploadIndex: Codable, Equatable {
    var uploadID: String
    var identityKey: String
    var rootHash: String
    var manifestChecksum: String
    var isManifestAccepted: Bool
    var isCompleteRequested: Bool
    /// Route availability this upload represents, recorded even when the route family is
    /// omitted from the manifest. Late-route reconciliation needs it after the receipt
    /// arrives, and the manifest alone cannot express "omitted because still pending".
    var routeAvailability: String
    var createdAt: Date
    var chunks: [EnrichmentChunkRecord]

    var pendingChunks: [EnrichmentChunkRecord] { chunks.filter { !$0.isUploaded } }
    var allChunksUploaded: Bool { chunks.allSatisfy { $0.isUploaded } }
}

/// What staging produced, handed to the uploader.
struct StagedEnrichmentUpload {
    var uploadID: String
    var directory: URL
    var index: EnrichmentUploadIndex
    var rootHash: String
    var familyHashes: [String: String]
    var routeAvailability: WorkoutDetailAvailability
    /// Counts for telemetry only — never identifiers.
    var routePointCount: Int
    var heartRatePointCount: Int
    var totalUncompressedBytes: Int
}

// MARK: - Deterministic chunk encoding

/// Serializes chunk bodies and decides where one chunk ends.
///
/// Numbers are formatted by hand with the same fixed-precision helpers the family hashes
/// use. `JSONSerialization` makes no promise about how it renders a `Double`, and a
/// change there across OS versions would make the same workout produce different bytes,
/// breaking both the replay guarantee and the checksums the server validates.
enum EnrichmentChunkEncoder {

    // MARK: Splitting

    /// Splits into chunks bounded by **both** serialized size and point count.
    ///
    /// Size is measured, not assumed: a route point serializes far wider than a
    /// heart-rate entry, so a fixed point-count limit alone would produce chunks that
    /// differ by an order of magnitude in bytes.
    static func split<T>(
        _ items: [T],
        cost: (T) -> Int,
        targetBytes: Int = EnrichmentWire.targetUncompressedChunkBytes,
        maximumCount: Int = EnrichmentWire.maximumPointsPerChunk
    ) -> [Range<Int>] {
        guard !items.isEmpty else { return [] }

        var ranges: [Range<Int>] = []
        var start = 0
        var accumulated = 0

        for index in items.indices {
            let itemCost = cost(items[index])
            let count = index - start

            // A single oversized item still gets its own chunk rather than being dropped.
            if count > 0 && (accumulated + itemCost > targetBytes || count >= maximumCount) {
                ranges.append(start..<index)
                start = index
                accumulated = 0
            }
            accumulated += itemCost
        }

        if start < items.count { ranges.append(start..<items.count) }
        return ranges
    }

    /// Each column contributes its rendered width plus one separator byte.
    static func routePointCost(_ point: RoutePoint) -> Int {
        var cost = String(EnrichmentWire.elapsedMicroseconds(point.elapsedOffset)).count + 1
        cost += WorkoutDetailHashing.coord(point.latitude).count + 1
        cost += WorkoutDetailHashing.coord(point.longitude).count + 1
        for value in [point.altitude, point.speed, point.course, point.horizontalAccuracy, point.verticalAccuracy] {
            cost += (value.map { WorkoutDetailHashing.num($0).count } ?? 4) + 1
        }
        return cost
    }

    static func quantityEntryCost(_ entry: QuantityEntry) -> Int {
        var cost = String(EnrichmentWire.elapsedMicroseconds(entry.startElapsedOffset)).count + 1
        cost += String(EnrichmentWire.elapsedMicroseconds(entry.endElapsedOffset)).count + 1
        cost += WorkoutDetailHashing.num(entry.value).count + 1
        cost += String(entry.ordinal).count + 1
        cost += entry.isExpandedFromSeries ? 11 : 3
        return cost
    }

    // MARK: Bodies

    /// Route chunk body. Arrays are aligned and ordered by ascending `elapsed_us` with
    /// `ordinal` as the tiebreak, exactly as the canonical hash orders them.
    static func routeChunkBody(partIndex: Int, points: [RoutePoint]) -> Data {
        let ordered = WorkoutDetailHashing.sortedPoints(points)

        var body = "{\"schema_version\":\(EnrichmentWire.schemaVersion),\"part_index\":\(partIndex)"
        body += column("elapsed_us", ordered.map { String(EnrichmentWire.elapsedMicroseconds($0.elapsedOffset)) })
        body += column("lat", ordered.map { WorkoutDetailHashing.coord($0.latitude) })
        body += column("lng", ordered.map { WorkoutDetailHashing.coord($0.longitude) })
        body += optionalColumn("altitude", ordered.map { $0.altitude })
        body += optionalColumn("speed", ordered.map { $0.speed })
        body += optionalColumn("course", ordered.map { $0.course })
        body += optionalColumn("h_acc", ordered.map { $0.horizontalAccuracy })
        body += optionalColumn("v_acc", ordered.map { $0.verticalAccuracy })
        // No route flag is defined in this slice. Emitting an invented one would be
        // fabricated data, so the column is explicitly null.
        body += ",\"flags\":null}"
        return Data(body.utf8)
    }

    /// Heart-rate (and later, any quantity) chunk body.
    ///
    /// `end_elapsed_us` is always sent: it is what distinguishes an instant reading from
    /// a coalesced interval whose value covers a span. The only flag emitted is `series`,
    /// which records that an entry came out of `HKQuantitySeriesSampleQuery` — real
    /// provenance that no other column carries.
    static func streamChunkBody(metric: String, entries: [QuantityEntry]) -> Data {
        let ordered = WorkoutDetailHashing.sortedEntries(entries)

        var body = "{\"schema_version\":\(EnrichmentWire.schemaVersion),\"metric\":\"\(metric)\""
        body += column("elapsed_us", ordered.map { String(EnrichmentWire.elapsedMicroseconds($0.startElapsedOffset)) })
        body += column("end_elapsed_us", ordered.map { String(EnrichmentWire.elapsedMicroseconds($0.endElapsedOffset)) })
        body += column("value", ordered.map { WorkoutDetailHashing.num($0.value) })
        body += column("ordinal", ordered.map { String($0.ordinal) })

        if ordered.contains(where: { $0.isExpandedFromSeries }) {
            let flags = ordered.map { $0.isExpandedFromSeries ? "[\"series\"]" : "[]" }
            body += ",\"flags\":[\(flags.joined(separator: ","))]"
        } else {
            body += ",\"flags\":null"
        }
        body += "}"
        return Data(body.utf8)
    }

    // MARK: Columns

    private static func column(_ name: String, _ values: [String]) -> String {
        ",\"\(name)\":[\(values.joined(separator: ","))]"
    }

    /// A column where every value is absent is sent as `null` rather than as an array of
    /// nulls, which is what the contract's `[float|null...]|null` shape means.
    private static func optionalColumn(_ name: String, _ values: [Double?]) -> String {
        guard values.contains(where: { $0 != nil }) else { return ",\"\(name)\":null" }
        let rendered = values.map { $0.map { WorkoutDetailHashing.num($0) } ?? "null" }
        return column(name, rendered)
    }
}

// MARK: - Outbox

/// File-backed staging area for workout-detail uploads.
///
/// Every file it writes contains precise location and physiological data, so every file
/// is excluded from backup and given a data-protection class before anything else
/// happens to it. Nothing here logs a path, a file name, an identifier, or a value.
final class EnrichmentOutbox {

    /// Staged uploads older than this are abandoned: HealthKit is still the source of
    /// truth, so re-reading is cheaper and safer than shipping a week-old staging area.
    static let expiry: TimeInterval = 7 * 24 * 3600

    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    var rootDirectory: URL { directory }

    func uploadDirectory(_ uploadID: String) -> URL {
        directory.appendingPathComponent(uploadID, isDirectory: true)
    }

    func manifestURL(_ uploadID: String) -> URL {
        uploadDirectory(uploadID).appendingPathComponent("manifest.json")
    }

    private func indexURL(_ uploadID: String) -> URL {
        uploadDirectory(uploadID).appendingPathComponent("index.json")
    }

    // MARK: Staging

    enum StagingError: Error {
        case serializationFailed
        case writeFailed
    }

    /// Writes the manifest and every chunk file for one collected workout.
    ///
    /// Chunks are encoded, compressed, and written one at a time and each buffer is
    /// released before the next is built, so peak memory is one chunk rather than the
    /// whole archive.
    func stage(
        detail: CollectedWorkoutDetail,
        routeAvailability: WorkoutDetailAvailability,
        now: Date = Date()
    ) throws -> StagedEnrichmentUpload {
        let hashes = WorkoutDetailHashing.hashes(for: detail)
        let identity = EnrichmentIdentityEnvelope(detail.identity)
        let uploadID = EnrichmentUploadID.derive(identityKey: identity.identityKey, rootContentHash: hashes.root)

        let uploadDirectory = uploadDirectory(uploadID)
        // A re-stage of the same content replaces the directory wholesale: identical
        // input reproduces identical bytes, so there is nothing to preserve.
        try? FileManager.default.removeItem(at: uploadDirectory)
        try? FileManager.default.createDirectory(at: uploadDirectory, withIntermediateDirectories: true)
        EnrichmentFileProtection.apply(to: directory)
        EnrichmentFileProtection.apply(to: uploadDirectory)

        var records: [EnrichmentChunkRecord] = []

        // Route — chunk indices run across the whole family, parts stay identified.
        var routeChunkIndex = 0
        var routeUncompressed = 0
        let orderedParts = WorkoutDetailHashing.sortedParts(detail.route.parts)
        var partSummaries: [EnrichmentRoutePartSummary] = []

        for part in orderedParts {
            let points = WorkoutDetailHashing.sortedPoints(part.points)
            partSummaries.append(EnrichmentRoutePartSummary(
                partIndex: part.partIndex,
                sourceRouteUUID: part.routeUUID.isEmpty ? nil : part.routeUUID,
                pointCount: points.count,
                contentHash: EnrichmentManifestBuilder.routePartHash(part)
            ))

            for range in EnrichmentChunkEncoder.split(points, cost: EnrichmentChunkEncoder.routePointCost) {
                let body = EnrichmentChunkEncoder.routeChunkBody(
                    partIndex: part.partIndex,
                    points: Array(points[range])
                )
                let fileName = String(format: "route_p%d_chunk%03d.json.gz", part.partIndex, routeChunkIndex)
                let record = try writeChunk(
                    body: body,
                    family: WorkoutDetailFamily.route.rawValue,
                    chunkIndex: routeChunkIndex,
                    partIndex: part.partIndex,
                    pointCount: range.count,
                    fileName: fileName,
                    in: uploadDirectory
                )
                routeUncompressed += record.uncompressedBytes
                records.append(record)
                routeChunkIndex += 1
            }
        }

        let routePointCount = orderedParts.reduce(0) { $0 + $1.points.count }

        // A family with no points is omitted, never sent empty. An empty read can mean
        // the source has not written the route yet, or that access is missing — Apple
        // makes those indistinguishable — and declaring an empty family would invite the
        // server to clear a route it already published (brief 6.4). Omission is the one
        // encoding that provably leaves published data alone.
        let routeSummary: EnrichmentRouteSummary? = routePointCount > 0
            ? EnrichmentRouteSummary(
                contentHash: hashes.route,
                chunkCount: routeChunkIndex,
                pointCount: routePointCount,
                uncompressedBytes: routeUncompressed,
                availability: routeAvailability,
                // The only discontinuity the source itself declares is the boundary
                // between two route objects.
                gapCount: max(0, orderedParts.count - 1),
                bounds: Self.bounds(of: orderedParts),
                parts: partSummaries
            )
            : nil

        // Heart rate.
        var heartRateChunkIndex = 0
        var heartRateUncompressed = 0
        let entries = WorkoutDetailHashing.sortedEntries(detail.heartRate.entries)

        for range in EnrichmentChunkEncoder.split(entries, cost: EnrichmentChunkEncoder.quantityEntryCost) {
            let body = EnrichmentChunkEncoder.streamChunkBody(
                metric: detail.heartRate.metric,
                entries: Array(entries[range])
            )
            let fileName = String(format: "heart_rate_chunk%03d.json.gz", heartRateChunkIndex)
            let record = try writeChunk(
                body: body,
                family: WorkoutDetailFamily.heartRate.rawValue,
                chunkIndex: heartRateChunkIndex,
                partIndex: nil,
                pointCount: range.count,
                fileName: fileName,
                in: uploadDirectory
            )
            heartRateUncompressed += record.uncompressedBytes
            records.append(record)
            heartRateChunkIndex += 1
        }

        let heartRateSummary: EnrichmentStreamSummary? = entries.isEmpty ? nil : EnrichmentStreamSummary(
            contentHash: hashes.heartRate,
            chunkCount: heartRateChunkIndex,
            pointCount: entries.count,
            uncompressedBytes: heartRateUncompressed,
            availability: detail.heartRate.availability,
            // Preparation guarantees one source per stream, so the first entry's key is
            // the stream's key.
            sourceKey: entries[0].sourceKey,
            unit: entries[0].unit,
            axis: entries.contains { $0.kind == .interval } ? "interval" : "point",
            sourceTypeIdentifier: detail.heartRate.quantityTypeIdentifier,
            coverage: (
                EnrichmentWire.elapsedMicroseconds(entries[0].startElapsedOffset),
                EnrichmentWire.elapsedMicroseconds(entries[entries.count - 1].endElapsedOffset)
            ),
            gaps: EnrichmentManifestBuilder.declaredGaps(
                events: detail.events.events,
                throughElapsedOffset: entries[entries.count - 1].endElapsedOffset
            )
        )

        // Manifest.
        let manifest = EnrichmentManifestBuilder.build(
            detail: detail,
            hashes: hashes,
            route: routeSummary,
            heartRate: heartRateSummary,
            includeEvents: !detail.events.events.isEmpty,
            includeActivities: !detail.activities.activities.isEmpty
        )
        guard let manifestData = try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]) else {
            throw StagingError.serializationFailed
        }
        let manifestURL = manifestURL(uploadID)
        do {
            try manifestData.write(to: manifestURL, options: .atomic)
        } catch {
            throw StagingError.writeFailed
        }
        EnrichmentFileProtection.apply(to: manifestURL)

        var familyHashes: [String: String] = [
            WorkoutDetailFamily.events.rawValue: hashes.events,
            WorkoutDetailFamily.activities.rawValue: hashes.activities
        ]
        if routeSummary != nil { familyHashes[WorkoutDetailFamily.route.rawValue] = hashes.route }
        if heartRateSummary != nil { familyHashes[WorkoutDetailFamily.heartRate.rawValue] = hashes.heartRate }

        let index = EnrichmentUploadIndex(
            uploadID: uploadID,
            identityKey: identity.identityKey,
            rootHash: hashes.root,
            manifestChecksum: WorkoutDetailHashing.sha256Hex(manifestData),
            isManifestAccepted: false,
            isCompleteRequested: false,
            routeAvailability: routeAvailability.rawValue,
            createdAt: now,
            chunks: records
        )
        save(index)

        return StagedEnrichmentUpload(
            uploadID: uploadID,
            directory: uploadDirectory,
            index: index,
            rootHash: hashes.root,
            familyHashes: familyHashes,
            routeAvailability: routeAvailability,
            routePointCount: routePointCount,
            heartRatePointCount: entries.count,
            totalUncompressedBytes: routeUncompressed + heartRateUncompressed
        )
    }

    private func writeChunk(
        body: Data,
        family: String,
        chunkIndex: Int,
        partIndex: Int?,
        pointCount: Int,
        fileName: String,
        in uploadDirectory: URL
    ) throws -> EnrichmentChunkRecord {
        // The checksum covers the uncompressed bytes, which is what the server re-derives
        // after inflating — checksumming the compressed form would not detect a bad
        // decompression.
        let checksum = WorkoutDetailHashing.sha256Hex(body)
        let compressed = EnrichmentGzip.compress(body)

        let url = uploadDirectory.appendingPathComponent(fileName)
        do {
            try compressed.write(to: url, options: .atomic)
        } catch {
            throw StagingError.writeFailed
        }
        EnrichmentFileProtection.apply(to: url)

        return EnrichmentChunkRecord(
            family: family,
            chunkIndex: chunkIndex,
            partIndex: partIndex,
            fileName: fileName,
            checksum: checksum,
            uncompressedBytes: body.count,
            compressedBytes: compressed.count,
            pointCount: pointCount,
            isUploaded: false
        )
    }

    private static func bounds(
        of parts: [RoutePart]
    ) -> (minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double)? {
        let points = parts.flatMap { $0.points }.filter { $0.latitude.isFinite && $0.longitude.isFinite }
        guard let first = points.first else { return nil }

        var result = (first.latitude, first.latitude, first.longitude, first.longitude)
        for point in points.dropFirst() {
            result.0 = min(result.0, point.latitude)
            result.1 = max(result.1, point.latitude)
            result.2 = min(result.2, point.longitude)
            result.3 = max(result.3, point.longitude)
        }
        return result
    }

    // MARK: Index

    func loadIndex(uploadID: String) -> EnrichmentUploadIndex? {
        guard let data = try? Data(contentsOf: indexURL(uploadID)) else { return nil }
        return try? JSONDecoder().decode(EnrichmentUploadIndex.self, from: data)
    }

    func save(_ index: EnrichmentUploadIndex) {
        guard let data = try? JSONEncoder().encode(index) else { return }
        let url = indexURL(index.uploadID)
        try? data.write(to: url, options: .atomic)
        EnrichmentFileProtection.apply(to: url)
    }

    @discardableResult
    func updateIndex(
        uploadID: String,
        _ body: (inout EnrichmentUploadIndex) -> Void
    ) -> EnrichmentUploadIndex? {
        guard var index = loadIndex(uploadID: uploadID) else { return nil }
        body(&index)
        save(index)
        return index
    }

    func markChunkUploaded(uploadID: String, fileName: String) {
        updateIndex(uploadID: uploadID) { index in
            guard let position = index.chunks.firstIndex(where: { $0.fileName == fileName }) else { return }
            index.chunks[position].isUploaded = true
        }
    }

    // MARK: Cleanup

    /// Removes one upload's staged files. Called on a terminal receipt, on a permanent
    /// failure, and when an upload is superseded by richer content.
    func remove(uploadID: String) {
        try? FileManager.default.removeItem(at: uploadDirectory(uploadID))
    }

    /// Removes everything. Sign-out, user switch, and explicit disable-and-delete.
    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Drops staged uploads past their expiry.
    @discardableResult
    func expireStaleUploads(now: Date = Date()) -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return 0 }

        var removed = 0
        for entry in entries {
            guard let index = loadIndex(uploadID: entry.lastPathComponent) else { continue }
            if now.timeIntervalSince(index.createdAt) > Self.expiry {
                try? FileManager.default.removeItem(at: entry)
                removed += 1
            }
        }
        return removed
    }

    /// Upload id whose directory name starts with `prefix`.
    ///
    /// Background task descriptions carry only a short upload-id prefix so nothing
    /// identifying reaches the system's task list; this resolves one back to its upload.
    func uploadID(matchingPrefix prefix: String) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        return entries.first { $0.hasPrefix(prefix) }
    }
}
