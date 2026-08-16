import Foundation

/// Produces a synthetic, committable JSON fixture from collected workout detail.
///
/// The fixture must stay useful for automated tests while retaining nothing that
/// identifies a person, a place, or a moment in time.
///
/// ## Redaction rules
///
/// 1. **Coordinates are translated and rotated.** The first route point of the first
///    part becomes the synthetic origin `(0, 0)`. Every point is projected into a
///    local east/north tangent plane around the real first point, rotated by an angle
///    derived from the redaction key, and projected back around latitude 0. Relative
///    geometry — pairwise distances, turn angles, and gap structure — survives; the
///    real location does not. The rotation means a fixture cannot be un-translated
///    even if someone guesses the start city.
/// 2. **Timestamps are rebased.** The workout start becomes
///    `2000-01-01T00:00:00Z` and every other date keeps its exact offset from it, so
///    all elapsed offsets, durations, and gaps are preserved bit-for-bit while the
///    real wall-clock time is gone.
/// 3. **Identifiers are replaced by keyed SHA-256 derivations.** HealthKit UUIDs,
///    sync/external identifiers, source bundle ids, source and device names, versions,
///    product types, and per-entry source keys become short synthetic tokens. The
///    derivation is stable for the same (input, key) pair — so a fixture regenerated
///    from the same workout is byte-identical — and non-reversible without the key.
/// 4. **Shapes are preserved.** Ordering, ordinals, point/interval kind, series
///    expansion flags, parent series counts, accuracy values, altitude, speed, course,
///    event boundaries and zero-duration laps, and activity positions are untouched.
///
/// Metadata keeps its structure without its content: Apple's documented `HK*` keys are
/// public constants and are kept verbatim, any other key is tokenised, and values are
/// kept only when they parse as a finite number (structural, non-identifying) and are
/// tokenised otherwise.
public enum WorkoutDetailFixtureWriter {

    /// Bump when the redaction rules change.
    public static let redactionVersion = 1

    /// 2000-01-01T00:00:00Z. Every fixture starts here.
    public static let syntheticEpoch = Date(timeIntervalSince1970: 946_684_800)

    /// WGS84 semi-major axis, used for the local tangent-plane projection.
    static let earthRadiusMetres = 6_378_137.0

    // MARK: - Public API

    /// Builds the redacted fixture as a JSON object tree.
    public static func makeFixture(from detail: CollectedWorkoutDetail, key: String) -> [String: Any] {
        let start = detail.identity.startDate
        let angle = rotationAngle(key: key)
        let origin = firstRoutePoint(in: detail.route)

        return [
            "manifest": manifest(for: detail),
            "identity": redactedIdentity(detail.identity, key: key, workoutStart: start),
            "route": redactedRoute(detail.route, key: key, workoutStart: start, origin: origin, angle: angle),
            "heart_rate": redactedHeartRate(detail.heartRate, key: key, workoutStart: start),
            "events": redactedEvents(detail.events, key: key, workoutStart: start),
            "activities": redactedActivities(detail.activities, key: key, workoutStart: start)
        ]
    }

    /// Serialises the fixture deterministically. Keys are sorted so the same input
    /// and key always produce the same bytes.
    public static func makeFixtureData(from detail: CollectedWorkoutDetail, key: String) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: makeFixture(from: detail, key: key),
            options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        )
    }

    /// Writes the fixture to disk. The caller is responsible for running
    /// `RedactionGuard` first — see the diagnostic example.
    public static func write(_ detail: CollectedWorkoutDetail, to url: URL, key: String) throws {
        try makeFixtureData(from: detail, key: key).write(to: url, options: .atomic)
    }

    // MARK: - Deterministic derivations

    /// Rotation angle in radians, derived from the key. Uniform over `[0, 2π)`.
    public static func rotationAngle(key: String) -> Double {
        let hex = WorkoutDetailHashing.keyedHex("route-rotation", key: key)
        let slice = String(hex.prefix(8))
        let raw = UInt32(slice, radix: 16) ?? 0
        return (Double(raw) / Double(UInt32.max)) * 2 * Double.pi
    }

    /// Short synthetic identifier, stable for a given `(value, key)` and not
    /// reversible without the key.
    public static func syntheticIdentifier(_ prefix: String, from value: String, key: String) -> String {
        let digest = WorkoutDetailHashing.keyedHex("\(prefix):\(value)", key: key)
        return "\(prefix)-\(digest.prefix(16))"
    }

    private static func syntheticIdentifier(_ prefix: String, fromOptional value: String?, key: String) -> Any {
        guard let value else { return NSNull() }
        return syntheticIdentifier(prefix, from: value, key: key)
    }

    /// Translates a coordinate into the tangent plane around `origin`, rotates it by
    /// `angle`, and re-projects it around the synthetic origin `(0, 0)`.
    ///
    /// Returns `(0, 0)` for the origin point itself. Distances are preserved to the
    /// accuracy of an equirectangular projection over the extent of one workout.
    public static func redactCoordinate(
        latitude: Double,
        longitude: Double,
        origin: (latitude: Double, longitude: Double),
        angle: Double
    ) -> (latitude: Double, longitude: Double) {
        let degreesToRadians = Double.pi / 180
        let radiansToDegrees = 180 / Double.pi

        let originLatitudeRadians = origin.latitude * degreesToRadians
        // East/north offsets in metres from the real first point.
        let north = (latitude - origin.latitude) * degreesToRadians * earthRadiusMetres
        let east = (longitude - origin.longitude) * degreesToRadians * earthRadiusMetres * cos(originLatitudeRadians)

        let rotatedEast = east * cos(angle) - north * sin(angle)
        let rotatedNorth = east * sin(angle) + north * cos(angle)

        // Re-project around latitude 0, where cos(latitude) == 1.
        return (
            latitude: (rotatedNorth / earthRadiusMetres) * radiansToDegrees,
            longitude: (rotatedEast / earthRadiusMetres) * radiansToDegrees
        )
    }

    /// Rebases a date onto the synthetic epoch, preserving its exact offset.
    public static func rebase(_ date: Date, workoutStart: Date) -> Date {
        syntheticEpoch.addingTimeInterval(date.timeIntervalSince(workoutStart))
    }

    // MARK: - Sections

    private static func manifest(for detail: CollectedWorkoutDetail) -> [String: Any] {
        [
            "schema_version": CollectedWorkoutDetail.schemaVersion,
            "redaction_version": redactionVersion,
            "canonicalization_version": WorkoutDetailHashing.canonicalizationVersion,
            "synthetic_epoch": isoString(syntheticEpoch),
            "counts": [
                "route_parts": detail.route.parts.count,
                "route_points": detail.route.pointCount,
                "heart_rate_entries": detail.heartRate.entries.count,
                "heart_rate_top_level_samples": detail.heartRate.topLevelSampleCount,
                "events": detail.events.events.count,
                "activities": detail.activities.activities.count
            ],
            "availability": [
                "route": detail.route.availability.rawValue,
                "heart_rate": detail.heartRate.availability.rawValue,
                "events": detail.events.availability.rawValue,
                "activities": detail.activities.availability.rawValue
            ]
        ]
    }

    private static func redactedIdentity(_ identity: WorkoutIdentity, key: String, workoutStart: Date) -> [String: Any] {
        [
            "workout_uuid": syntheticIdentifier("wk", from: identity.workoutUUID, key: key),
            "sync_identifier": syntheticIdentifier("sync", fromOptional: identity.syncIdentifier, key: key),
            // The version number itself is structural, not identifying.
            "sync_version": identity.syncVersion.map { $0 as Any } ?? NSNull(),
            "external_uuid": syntheticIdentifier("ext", fromOptional: identity.externalUUID, key: key),
            "source_bundle_id": syntheticIdentifier("src", from: identity.sourceBundleIdentifier, key: key),
            "source_name": syntheticIdentifier("srcname", from: identity.sourceName, key: key),
            "source_version": syntheticIdentifier("srcver", fromOptional: identity.sourceVersion, key: key),
            "source_product_type": syntheticIdentifier("product", fromOptional: identity.sourceProductType, key: key),
            "source_os_version": syntheticIdentifier("os", fromOptional: identity.sourceOperatingSystemVersion, key: key),
            "device_name": syntheticIdentifier("devname", fromOptional: identity.deviceName, key: key),
            "device_manufacturer": syntheticIdentifier("mfr", fromOptional: identity.deviceManufacturer, key: key),
            "device_model": syntheticIdentifier("model", fromOptional: identity.deviceModel, key: key),
            "device_hardware_version": syntheticIdentifier("hw", fromOptional: identity.deviceHardwareVersion, key: key),
            "device_software_version": syntheticIdentifier("sw", fromOptional: identity.deviceSoftwareVersion, key: key),
            // The offset is kept (it shapes local-time rendering); the zone name is not,
            // because a zone identifier narrows down where the workout happened.
            "time_zone_offset_s": identity.timeZoneOffsetSeconds.map { $0 as Any } ?? NSNull(),
            "activity_type_raw": identity.activityTypeRawValue,
            "activity_type_name": identity.activityTypeName,
            "start_date": isoString(syntheticEpoch),
            "end_date": isoString(rebase(identity.endDate, workoutStart: workoutStart)),
            "duration_s": identity.duration,
            "span_s": identity.endDate.timeIntervalSince(identity.startDate)
        ]
    }

    private static func redactedRoute(
        _ route: WorkoutRouteDetail,
        key: String,
        workoutStart: Date,
        origin: (latitude: Double, longitude: Double)?,
        angle: Double
    ) -> [String: Any] {
        let parts: [[String: Any]] = WorkoutDetailHashing.sortedParts(route.parts).map { part in
            let points: [[String: Any]] = WorkoutDetailHashing.sortedPoints(part.points).map { point in
                var redactedLatitude = 0.0
                var redactedLongitude = 0.0
                if let origin {
                    let moved = redactCoordinate(
                        latitude: point.latitude,
                        longitude: point.longitude,
                        origin: origin,
                        angle: angle
                    )
                    redactedLatitude = moved.latitude
                    redactedLongitude = moved.longitude
                }
                var entry: [String: Any] = [
                    "elapsed_offset_s": point.elapsedOffset,
                    "ordinal": point.ordinal,
                    "latitude": redactedLatitude,
                    "longitude": redactedLongitude,
                    "timestamp": isoString(rebase(point.timestamp, workoutStart: workoutStart))
                ]
                // Accuracy and motion values are quality signals, not identifiers.
                entry["altitude_m"] = point.altitude.map { $0 as Any } ?? NSNull()
                entry["speed_mps"] = point.speed.map { $0 as Any } ?? NSNull()
                entry["course_deg"] = point.course.map { $0 as Any } ?? NSNull()
                entry["horizontal_accuracy_m"] = point.horizontalAccuracy.map { $0 as Any } ?? NSNull()
                entry["vertical_accuracy_m"] = point.verticalAccuracy.map { $0 as Any } ?? NSNull()
                return entry
            }
            return [
                "route_uuid": syntheticIdentifier("rt", from: part.routeUUID, key: key),
                "part_index": part.partIndex,
                "batch_count": part.batchCount,
                "point_count": part.points.count,
                "points": points
            ]
        }

        return [
            "availability": route.availability.rawValue,
            "synthetic_origin": ["latitude": 0.0, "longitude": 0.0],
            "rotation_applied": origin != nil,
            "parts": parts
        ]
    }

    private static func redactedHeartRate(
        _ stream: WorkoutQuantityStream,
        key: String,
        workoutStart: Date
    ) -> [String: Any] {
        let entries: [[String: Any]] = WorkoutDetailHashing.sortedEntries(stream.entries).map { entry in
            [
                "start_elapsed_offset_s": entry.startElapsedOffset,
                "end_elapsed_offset_s": entry.endElapsedOffset,
                "start_date": isoString(rebase(entry.startDate, workoutStart: workoutStart)),
                "end_date": isoString(rebase(entry.endDate, workoutStart: workoutStart)),
                "ordinal": entry.ordinal,
                "value": entry.value,
                "unit": entry.unit,
                // Point vs interval must survive: it is the condensed-series semantics.
                "kind": entry.kind.rawValue,
                "expanded_from_series": entry.isExpandedFromSeries,
                "parent_series_count": entry.parentSeriesCount,
                "sample_uuid": syntheticIdentifier("smp", fromOptional: entry.sampleUUID, key: key),
                "source_key": syntheticIdentifier("srckey", from: entry.sourceKey, key: key)
            ]
        }

        return [
            "availability": stream.availability.rawValue,
            "metric": stream.metric,
            "quantity_type": stream.quantityTypeIdentifier,
            "top_level_sample_count": stream.topLevelSampleCount,
            "entry_count": stream.entries.count,
            "entries": entries
        ]
    }

    private static func redactedEvents(
        _ detail: WorkoutEventsDetail,
        key: String,
        workoutStart: Date
    ) -> [String: Any] {
        let events: [[String: Any]] = WorkoutDetailHashing.sortedEvents(detail.events).map { event in
            [
                "type_raw": event.typeRawValue,
                "type_name": event.typeName,
                "start_elapsed_offset_s": event.startElapsedOffset,
                "end_elapsed_offset_s": event.endElapsedOffset,
                "start_date": isoString(rebase(event.startDate, workoutStart: workoutStart)),
                "end_date": isoString(rebase(event.endDate, workoutStart: workoutStart)),
                // Legacy zero-duration laps stay zero-duration.
                "zero_duration": event.isZeroDuration,
                "ordinal": event.ordinal,
                "metadata": redactedMetadata(event.metadata, key: key)
            ]
        }

        return [
            "availability": detail.availability.rawValue,
            "event_count": detail.events.count,
            "events": events
        ]
    }

    private static func redactedActivities(
        _ detail: WorkoutActivitiesDetail,
        key: String,
        workoutStart: Date
    ) -> [String: Any] {
        let activities: [[String: Any]] = WorkoutDetailHashing.sortedActivities(detail.activities).map { activity in
            let statistics: [[String: Any]] = activity.statistics.map { statistic in
                [
                    "quantity_type": statistic.quantityTypeIdentifier,
                    "aggregation": statistic.aggregation,
                    "value": statistic.value,
                    "unit": statistic.unit
                ]
            }
            var entry: [String: Any] = [
                "activity_uuid": syntheticIdentifier("act", from: activity.activityUUID, key: key),
                "position": activity.position,
                "activity_type_raw": activity.activityTypeRawValue,
                "activity_type_name": activity.activityTypeName,
                "start_elapsed_offset_s": activity.startElapsedOffset,
                "start_date": isoString(rebase(activity.startDate, workoutStart: workoutStart)),
                "duration_s": activity.duration,
                "statistics": statistics,
                "metadata": redactedMetadata(activity.metadata, key: key)
            ]
            entry["end_elapsed_offset_s"] = activity.endElapsedOffset.map { $0 as Any } ?? NSNull()
            entry["end_date"] = activity.endDate.map { isoString(rebase($0, workoutStart: workoutStart)) as Any } ?? NSNull()
            return entry
        }

        return [
            "availability": detail.availability.rawValue,
            "os_supported": detail.isSupportedOnThisOS,
            "activity_count": detail.activities.count,
            "activities": activities
        ]
    }

    // MARK: - Metadata

    /// Keeps metadata shape without keeping metadata content.
    ///
    /// Apple's `HK*` keys are documented public constants and stay verbatim so the
    /// fixture still shows which native keys a source writes. Any other key comes from
    /// a third-party app and is tokenised. Values are kept only when they parse as a
    /// finite number; everything else is tokenised, because a free-text value can hold
    /// a workout title, a place, or a user name.
    static func redactedMetadata(_ metadata: [String: String], key: String) -> [String: Any] {
        var result: [String: Any] = [:]
        for (metadataKey, value) in metadata {
            let outputKey = metadataKey.hasPrefix("HK")
                ? metadataKey
                : syntheticIdentifier("mkey", from: metadataKey, key: key)
            if let number = Double(value), number.isFinite {
                result[outputKey] = number
            } else {
                result[outputKey] = syntheticIdentifier("mval", from: value, key: key)
            }
        }
        return result
    }

    // MARK: - Helpers

    private static func firstRoutePoint(in route: WorkoutRouteDetail) -> (latitude: Double, longitude: Double)? {
        for part in WorkoutDetailHashing.sortedParts(route.parts) {
            if let point = WorkoutDetailHashing.sortedPoints(part.points).first {
                return (point.latitude, point.longitude)
            }
        }
        return nil
    }

    /// Fixed-format ISO-8601 in UTC with milliseconds. Locale- and timezone-independent
    /// so a fixture generated on any device is byte-identical.
    static func isoString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: date)
    }
}
