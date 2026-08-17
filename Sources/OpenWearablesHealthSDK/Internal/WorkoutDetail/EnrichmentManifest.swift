import Foundation

/// The pinned workout-detail wire contract (schema version 1), expressed in Swift.
///
/// Field names, paths, and header names in this file are the contract. Renaming any of
/// them breaks the server without a compile error on either side, so they are written
/// as literals here exactly once and referenced everywhere else.
enum EnrichmentWire {

    static let schemaVersion = 1
    static let provider = "apple"

    /// Base path under the SDK API root: `/api/v1/sdk/users/{user_id}/workout-details`.
    static let basePathComponent = "workout-details"

    // MARK: Chunking limits

    /// Target uncompressed bytes per chunk. Chunking is driven by serialized size, not
    /// only point count, because a route point and a heart-rate entry differ in width.
    static let targetUncompressedChunkBytes = 1 * 1024 * 1024
    /// Server rejects a compressed chunk above this with 413.
    static let maximumCompressedChunkBytes = 4 * 1024 * 1024
    /// Server rejects more points than this in one chunk with 422.
    static let maximumPointsPerChunk = 16_384

    /// Inline families are carried in the manifest itself and are capped by the server.
    static let maximumInlineEvents = 2_000
    static let maximumInlineActivities = 200

    // MARK: Headers

    static let checksumHeader = "X-Chunk-Checksum"
    static let uncompressedBytesHeader = "X-Uncompressed-Bytes"
    static let contentEncodingHeader = "Content-Encoding"
    static let gzipEncoding = "gzip"

    // MARK: Event types

    /// The only event types the pinned contract can carry.
    ///
    /// `HKWorkoutEventType` has values with no slot here (for example
    /// `pauseOrResumeRequest`, and any type a future OS adds). Flattening one of those
    /// into a neighbouring type would corrupt the data, so an unmappable event is left
    /// out and its family is reported `partial` — honest about the omission instead of
    /// inventing a classification.
    static func wireEventType(forHealthKitRawValue rawValue: Int) -> String? {
        switch rawValue {
        case 1: return "pause"
        case 2: return "resume"
        case 3: return "lap"
        case 4: return "marker"
        case 5: return "automatic_pause"
        case 6: return "automatic_resume"
        case 7: return "segment"
        default: return nil
        }
    }

    // MARK: Scalars

    /// Elapsed offsets travel as integer microseconds, so no float rounding drift can
    /// reorder two points that the device saw in a definite order.
    static func elapsedMicroseconds(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite else { return 0 }
        return Int((seconds * 1_000_000).rounded())
    }

    /// ISO 8601 with an explicit offset, in the workout's original zone when the source
    /// recorded one. Absolute timestamps are contract-required in upload bodies; they
    /// never reach a log.
    static func timestamp(_ date: Date, offsetSeconds: Int?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: offsetSeconds ?? 0) ?? TimeZone(identifier: "UTC")!
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
        return formatter.string(from: date)
    }

    /// `"+01:00"` / `"-05:30"` / `"+00:00"`.
    static func offsetLabel(_ offsetSeconds: Int) -> String {
        let sign = offsetSeconds < 0 ? "-" : "+"
        let absolute = abs(offsetSeconds)
        return String(format: "%@%02d:%02d", sign, absolute / 3600, (absolute % 3600) / 60)
    }
}

// MARK: - Identity envelope

/// The identity the server resolves an upload against, and the only thing the device
/// needs to keep after a workout is deleted from HealthKit so it can still tombstone it.
///
/// Stored in the checkpoint, sent in the manifest, and sent in the tombstone body.
struct EnrichmentIdentityEnvelope: Codable, Equatable {
    var healthKitWorkoutUUID: String?
    var sourceBundleIdentifier: String?
    var syncIdentifier: String?
    var syncVersion: Int?
    var externalUUID: String?
    var sourceName: String?
    var sourceVersion: String?
    var deviceManufacturer: String?
    var deviceModel: String?
    var deviceProductType: String?
    var originalTimeZoneOffsetSeconds: Int?
    var startDate: Date
    var endDate: Date
    var workoutType: String

    init(_ identity: WorkoutIdentity) {
        healthKitWorkoutUUID = identity.workoutUUID
        sourceBundleIdentifier = identity.sourceBundleIdentifier
        syncIdentifier = identity.syncIdentifier
        syncVersion = identity.syncVersion
        externalUUID = identity.externalUUID
        sourceName = identity.sourceName
        sourceVersion = identity.sourceVersion
        deviceManufacturer = identity.deviceManufacturer
        deviceModel = identity.deviceModel
        deviceProductType = identity.sourceProductType
        originalTimeZoneOffsetSeconds = identity.timeZoneOffsetSeconds
        startDate = identity.startDate
        endDate = identity.endDate
        workoutType = identity.activityTypeName
    }

    /// The logical identity key, per the pinned derivation: a trustworthy source bundle
    /// plus HealthKit sync identifier when the source wrote one, otherwise the workout
    /// UUID. Start/end time is never an identity.
    var identityKey: String {
        if let syncIdentifier, !syncIdentifier.isEmpty {
            return "\(EnrichmentWire.provider)|\(sourceBundleIdentifier ?? "")|\(syncIdentifier)"
        }
        return "\(EnrichmentWire.provider)|\(healthKitWorkoutUUID ?? "")"
    }

    /// Manifest `identity` object.
    var manifestObject: [String: Any] {
        var object: [String: Any] = [
            "provider": EnrichmentWire.provider,
            "healthkit_workout_uuid": healthKitWorkoutUUID as Any? ?? NSNull(),
            "source_bundle_id": sourceBundleIdentifier as Any? ?? NSNull(),
            "healthkit_sync_identifier": syncIdentifier as Any? ?? NSNull(),
            "healthkit_sync_version": syncVersion as Any? ?? NSNull(),
            "external_uuid": externalUUID as Any? ?? NSNull(),
            "source_name": sourceName as Any? ?? NSNull(),
            "source_version": sourceVersion as Any? ?? NSNull(),
            "device_manufacturer": deviceManufacturer as Any? ?? NSNull(),
            "device_model": deviceModel as Any? ?? NSNull(),
            "device_product_type": deviceProductType as Any? ?? NSNull(),
            "start_datetime": EnrichmentWire.timestamp(startDate, offsetSeconds: originalTimeZoneOffsetSeconds),
            "end_datetime": EnrichmentWire.timestamp(endDate, offsetSeconds: originalTimeZoneOffsetSeconds),
            "workout_type": workoutType
        ]
        object["original_timezone_offset"] = originalTimeZoneOffsetSeconds
            .map { EnrichmentWire.offsetLabel($0) } as Any? ?? NSNull()
        return object
    }

    /// Tombstone body: only what the server needs to resolve the deleted workout.
    func tombstoneObject(deletedAt: Date) -> [String: Any] {
        [
            "schema_version": EnrichmentWire.schemaVersion,
            "identity": [
                "provider": EnrichmentWire.provider,
                "healthkit_workout_uuid": healthKitWorkoutUUID as Any? ?? NSNull(),
                "source_bundle_id": sourceBundleIdentifier as Any? ?? NSNull(),
                "healthkit_sync_identifier": syncIdentifier as Any? ?? NSNull()
            ],
            "deleted_at": EnrichmentWire.timestamp(deletedAt, offsetSeconds: 0)
        ]
    }
}

// MARK: - Upload identifier

enum EnrichmentUploadID {

    /// `first 32 hex of sha256("owd1|" + identityKey + "|" + rootContentHash)`.
    ///
    /// Same content retried yields the same upload, so a replay is idempotent; richer
    /// content yields a different root hash and therefore a new upload.
    static func derive(identityKey: String, rootContentHash: String) -> String {
        String(WorkoutDetailHashing.sha256Hex("owd1|\(identityKey)|\(rootContentHash)").prefix(32))
    }

    /// Short, non-reversible label safe for `taskDescription` and telemetry.
    static func logPrefix(_ uploadID: String) -> String { String(uploadID.prefix(8)) }
}

// MARK: - Preparation

/// Reduces collected detail to exactly what the pinned contract can carry, before any
/// hash is computed.
///
/// Hashing what is actually uploaded (rather than what was read) is what makes the root
/// hash — and therefore the upload id — describe the bytes the server will validate.
enum EnrichmentPreparation {

    struct Result {
        /// Detail filtered to contract-representable content. Hash this, not the input.
        var detail: CollectedWorkoutDetail
        /// Heart-rate entries dropped because they came from a non-dominant source.
        var droppedForeignSourceEntryCount: Int
        /// Events dropped because their native type has no slot in the contract.
        var droppedUnmappableEventCount: Int
    }

    static func prepare(_ detail: CollectedWorkoutDetail) -> Result {
        var prepared = detail

        // Heart rate: the contract pins one `source_key` per stream. Merging a watch and
        // a chest strap into one stream would silently fabricate a single sensor, so the
        // dominant source is sent and the family is marked partial when another source
        // also contributed.
        var droppedEntries = 0
        let entries = detail.heartRate.entries
        if !entries.isEmpty {
            var countsBySource: [String: Int] = [:]
            for entry in entries { countsBySource[entry.sourceKey, default: 0] += 1 }

            if countsBySource.count > 1 {
                let dominant = countsBySource
                    .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                    .first!.key
                let kept = entries.filter { $0.sourceKey == dominant }
                droppedEntries = entries.count - kept.count
                prepared.heartRate.entries = kept
                prepared.heartRate.availability = kept.isEmpty ? .notAvailableOrNotAuthorized : .partial
            }
        }

        // Events: keep every type the contract can express, drop the rest rather than
        // flattening it into a neighbouring type.
        let mappable = detail.events.events.filter {
            EnrichmentWire.wireEventType(forHealthKitRawValue: $0.typeRawValue) != nil
        }
        let droppedEvents = detail.events.events.count - mappable.count
        if droppedEvents > 0 {
            prepared.events.events = mappable
            prepared.events.availability = mappable.isEmpty ? .notAvailableOrNotAuthorized : .partial
        }

        // Inline families are size-capped by the server. Exceeding a cap is reported as
        // partial rather than silently truncated mid-list.
        if prepared.events.events.count > EnrichmentWire.maximumInlineEvents {
            prepared.events.events = Array(
                WorkoutDetailHashing.sortedEvents(prepared.events.events).prefix(EnrichmentWire.maximumInlineEvents)
            )
            prepared.events.availability = .partial
        }
        if prepared.activities.activities.count > EnrichmentWire.maximumInlineActivities {
            prepared.activities.activities = Array(
                WorkoutDetailHashing.sortedActivities(prepared.activities.activities)
                    .prefix(EnrichmentWire.maximumInlineActivities)
            )
            prepared.activities.availability = .partial
        }

        return Result(
            detail: prepared,
            droppedForeignSourceEntryCount: droppedEntries,
            droppedUnmappableEventCount: droppedEvents
        )
    }

    /// Route availability at publish time.
    ///
    /// A source may write a route minutes or hours after the workout ends, so an absent
    /// route is only `not_available_or_not_authorized` once that window has passed;
    /// before then it is `pending_enrichment` and stays eligible for reconciliation.
    static let lateRouteWindow: TimeInterval = 24 * 3600

    static func routeAvailability(
        _ route: WorkoutRouteDetail,
        workoutEnd: Date,
        now: Date = Date()
    ) -> WorkoutDetailAvailability {
        guard route.availability == .notAvailableOrNotAuthorized, route.pointCount == 0 else {
            return route.availability
        }
        return now.timeIntervalSince(workoutEnd) < lateRouteWindow ? .pendingEnrichment : .notAvailableOrNotAuthorized
    }
}

// MARK: - Family summaries

/// One route object as summarized in the manifest.
struct EnrichmentRoutePartSummary {
    var partIndex: Int
    var sourceRouteUUID: String?
    var pointCount: Int
    var contentHash: String

    var manifestObject: [String: Any] {
        [
            "part_index": partIndex,
            "source_route_uuid": sourceRouteUUID as Any? ?? NSNull(),
            "point_count": pointCount,
            "content_hash": contentHash
        ]
    }
}

struct EnrichmentRouteSummary {
    var contentHash: String
    var chunkCount: Int
    var pointCount: Int
    var uncompressedBytes: Int
    var availability: WorkoutDetailAvailability
    /// Discontinuities the source itself declared: each boundary between two
    /// `HKWorkoutRoute` objects. No distance or time threshold is applied, because
    /// HealthKit publishes no sampling cadence to compare against.
    var gapCount: Int
    var bounds: (minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double)?
    var parts: [EnrichmentRoutePartSummary]

    var manifestObject: [String: Any] {
        var object: [String: Any] = [
            "content_hash": contentHash,
            "chunk_count": chunkCount,
            "point_count": pointCount,
            "uncompressed_bytes": uncompressedBytes,
            "availability": availability.rawValue,
            "gap_count": gapCount,
            "parts": parts.map { $0.manifestObject }
        ]
        if let bounds {
            object["bounds"] = [
                "min_lat": bounds.minLatitude,
                "max_lat": bounds.maxLatitude,
                "min_lng": bounds.minLongitude,
                "max_lng": bounds.maxLongitude
            ]
        } else {
            object["bounds"] = NSNull()
        }
        return object
    }
}

struct EnrichmentStreamSummary {
    var contentHash: String
    var chunkCount: Int
    var pointCount: Int
    var uncompressedBytes: Int
    var availability: WorkoutDetailAvailability
    var sourceKey: String
    var unit: String
    /// `interval` when any entry covers a span — a coalesced sample's value applies
    /// across its whole span and must not be read as an instant.
    var axis: String
    var sourceTypeIdentifier: String
    var coverage: (fromElapsedMicroseconds: Int, throughElapsedMicroseconds: Int)?
    /// Spans the source declared as paused, from its own pause/resume events. Never a
    /// threshold guess about "too long between samples".
    var gaps: [(startElapsedMicroseconds: Int, endElapsedMicroseconds: Int)]

    var manifestObject: [String: Any] {
        var object: [String: Any] = [
            "content_hash": contentHash,
            "chunk_count": chunkCount,
            "point_count": pointCount,
            "uncompressed_bytes": uncompressedBytes,
            "availability": availability.rawValue,
            "source_key": sourceKey,
            "unit": unit,
            "axis": axis,
            "source_type_identifier": sourceTypeIdentifier,
            "gaps": gaps.map { ["start_elapsed_us": $0.startElapsedMicroseconds, "end_elapsed_us": $0.endElapsedMicroseconds] }
        ]
        if let coverage {
            object["coverage"] = [
                "observed_from_elapsed_us": coverage.fromElapsedMicroseconds,
                "observed_through_elapsed_us": coverage.throughElapsedMicroseconds
            ]
        } else {
            object["coverage"] = NSNull()
        }
        return object
    }
}

// MARK: - Manifest builder

enum EnrichmentManifestBuilder {

    /// Builds the manifest body for a prepared detail.
    ///
    /// `omittedFamilies` lists families this upload deliberately does not address, which
    /// the server reads as "leave the published family unchanged" — the mechanism that
    /// lets a late route be published without re-uploading an unchanged heart-rate stream.
    static func build(
        detail: CollectedWorkoutDetail,
        hashes: WorkoutDetailHashing.Hashes,
        route: EnrichmentRouteSummary?,
        heartRate: EnrichmentStreamSummary?,
        includeEvents: Bool,
        includeActivities: Bool
    ) -> [String: Any] {
        var families: [String: Any] = [:]
        var omitted: [String] = []

        if let route {
            families[WorkoutDetailFamily.route.rawValue] = route.manifestObject
        } else {
            omitted.append(WorkoutDetailFamily.route.rawValue)
        }

        if let heartRate {
            families[WorkoutDetailFamily.heartRate.rawValue] = heartRate.manifestObject
        } else {
            omitted.append(WorkoutDetailFamily.heartRate.rawValue)
        }

        if includeEvents {
            families[WorkoutDetailFamily.events.rawValue] = eventsObject(detail, hash: hashes.events)
        } else {
            omitted.append(WorkoutDetailFamily.events.rawValue)
        }

        if includeActivities {
            families[WorkoutDetailFamily.activities.rawValue] = activitiesObject(detail, hash: hashes.activities)
        } else {
            omitted.append(WorkoutDetailFamily.activities.rawValue)
        }

        return [
            "schema_version": EnrichmentWire.schemaVersion,
            "identity": EnrichmentIdentityEnvelope(detail.identity).manifestObject,
            "families": families,
            "omitted_families": omitted
        ]
    }

    // MARK: Inline families

    static func eventsObject(_ detail: CollectedWorkoutDetail, hash: String) -> [String: Any] {
        let offset = detail.identity.timeZoneOffsetSeconds
        let entries = WorkoutDetailHashing.sortedEvents(detail.events.events)
            .enumerated()
            .compactMap { index, event -> [String: Any]? in
                guard let type = EnrichmentWire.wireEventType(forHealthKitRawValue: event.typeRawValue) else { return nil }

                // A zero-duration legacy lap marker keeps its zero duration: it is
                // reported with no end rather than widened into a synthetic interval.
                let hasEnd = !event.isZeroDuration
                var object: [String: Any] = [
                    "event_index": index,
                    "event_type": type,
                    "start_timestamp": EnrichmentWire.timestamp(event.startDate, offsetSeconds: offset),
                    "end_timestamp": hasEnd
                        ? EnrichmentWire.timestamp(event.endDate, offsetSeconds: offset) as Any
                        : NSNull(),
                    "start_elapsed_us": EnrichmentWire.elapsedMicroseconds(event.startElapsedOffset),
                    "end_elapsed_us": hasEnd
                        ? EnrichmentWire.elapsedMicroseconds(event.endElapsedOffset) as Any
                        : NSNull(),
                    "content_id": eventContentID(event)
                ]
                object["source_metadata"] = event.metadata.isEmpty ? NSNull() : event.metadata
                return object
            }

        return ["content_hash": hash, "entries": entries]
    }

    static func activitiesObject(_ detail: CollectedWorkoutDetail, hash: String) -> [String: Any] {
        let offset = detail.identity.timeZoneOffsetSeconds
        let entries = WorkoutDetailHashing.sortedActivities(detail.activities.activities).map { activity -> [String: Any] in
            var object: [String: Any] = [
                "position": activity.position,
                "activity_uuid": activity.activityUUID.isEmpty ? NSNull() : activity.activityUUID,
                "activity_type": activity.activityTypeName,
                "start_timestamp": EnrichmentWire.timestamp(activity.startDate, offsetSeconds: offset),
                "end_timestamp": activity.endDate
                    .map { EnrichmentWire.timestamp($0, offsetSeconds: offset) } as Any? ?? NSNull(),
                "start_elapsed_us": EnrichmentWire.elapsedMicroseconds(activity.startElapsedOffset),
                "end_elapsed_us": activity.endElapsedOffset
                    .map { EnrichmentWire.elapsedMicroseconds($0) } as Any? ?? NSNull(),
                "content_hash": activityContentHash(activity)
            ]

            if activity.statistics.isEmpty {
                object["statistics"] = NSNull()
            } else {
                var statistics: [String: [String: Any]] = [:]
                for statistic in activity.statistics {
                    var bucket = statistics[statistic.quantityTypeIdentifier] ?? [:]
                    bucket[statistic.aggregation] = statistic.value
                    bucket["unit"] = statistic.unit
                    statistics[statistic.quantityTypeIdentifier] = bucket
                }
                object["statistics"] = statistics
            }

            var configuration: [String: Any] = ["activity_type_raw_value": activity.activityTypeRawValue]
            if !activity.metadata.isEmpty { configuration["metadata"] = activity.metadata }
            object["configuration"] = configuration

            return object
        }

        return ["content_hash": hash, "entries": entries]
    }

    // MARK: Per-entry content identity

    /// Stable identity for one event, derived from its canonical form so the same event
    /// re-read after a retry produces the same id.
    static func eventContentID(_ event: WorkoutEventEntry) -> String {
        let canonical = [
            "ev",
            WorkoutDetailHashing.num(event.startElapsedOffset),
            WorkoutDetailHashing.num(event.endElapsedOffset),
            String(event.typeRawValue),
            String(event.ordinal),
            WorkoutDetailHashing.canonicalMetadata(event.metadata)
        ].joined(separator: "|")
        return String(WorkoutDetailHashing.sha256Hex(canonical).prefix(32))
    }

    static func activityContentHash(_ activity: WorkoutActivityEntry) -> String {
        var canonical = [
            "ac",
            String(activity.position),
            activity.activityUUID,
            String(activity.activityTypeRawValue),
            WorkoutDetailHashing.num(activity.startElapsedOffset),
            WorkoutDetailHashing.optionalNum(activity.endElapsedOffset),
            WorkoutDetailHashing.num(activity.duration),
            WorkoutDetailHashing.canonicalMetadata(activity.metadata)
        ].joined(separator: "|")
        for statistic in activity.statistics.sorted(by: {
            $0.quantityTypeIdentifier == $1.quantityTypeIdentifier
                ? $0.aggregation < $1.aggregation
                : $0.quantityTypeIdentifier < $1.quantityTypeIdentifier
        }) {
            canonical += "\nst=\(statistic.quantityTypeIdentifier)|\(statistic.aggregation)"
                + "|\(WorkoutDetailHashing.num(statistic.value))|\(statistic.unit)"
        }
        return WorkoutDetailHashing.sha256Hex(canonical)
    }

    /// Per-route-object hash, so a manifest can prove which route part changed without
    /// re-hashing the whole family.
    static func routePartHash(_ part: RoutePart) -> String {
        WorkoutDetailHashing.sha256Hex(
            WorkoutDetailHashing.canonicalRoute(WorkoutRouteDetail(availability: .available, parts: [part]))
        )
    }

    /// Paused spans declared by the workout's own pause/resume events, in microseconds.
    /// An unmatched pause closes at the last observed sample rather than being guessed.
    static func declaredGaps(
        events: [WorkoutEventEntry],
        throughElapsedOffset: TimeInterval?
    ) -> [(startElapsedMicroseconds: Int, endElapsedMicroseconds: Int)] {
        var gaps: [(startElapsedMicroseconds: Int, endElapsedMicroseconds: Int)] = []
        var openPause: TimeInterval?

        for event in WorkoutDetailHashing.sortedEvents(events) {
            switch event.typeRawValue {
            case 1, 5: // pause, automatic pause
                if openPause == nil { openPause = event.startElapsedOffset }
            case 2, 6: // resume, automatic resume
                if let start = openPause, event.startElapsedOffset > start {
                    gaps.append((
                        EnrichmentWire.elapsedMicroseconds(start),
                        EnrichmentWire.elapsedMicroseconds(event.startElapsedOffset)
                    ))
                }
                openPause = nil
            default:
                break
            }
        }

        if let start = openPause, let through = throughElapsedOffset, through > start {
            gaps.append((
                EnrichmentWire.elapsedMicroseconds(start),
                EnrichmentWire.elapsedMicroseconds(through)
            ))
        }
        return gaps
    }
}
