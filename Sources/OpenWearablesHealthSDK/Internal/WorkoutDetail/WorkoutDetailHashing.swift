import Foundation
import CryptoKit

/// Deterministic canonical serialization and SHA-256 family hashes for collected
/// workout detail.
///
/// ## Ordering rules
///
/// Hashing must not depend on the order HealthKit happened to deliver objects, so
/// every collection is canonically sorted before it is serialized:
///
/// - **Route parts** — ascending `partIndex`, ties broken by `routeUUID`.
/// - **Route points** — ascending `elapsedOffset`, ties broken by `ordinal`.
/// - **Heart-rate entries** — ascending `startElapsedOffset`, then `endElapsedOffset`,
///   then `ordinal`. Equal timestamps are legal and are kept, not deduplicated.
/// - **Events** — ascending `startElapsedOffset`, then `endElapsedOffset`, then
///   `typeRawValue`, then `ordinal`. Overlapping segments are legal.
/// - **Activities** — ascending `position`, ties broken by `activityUUID`.
/// - **Metadata dictionaries** — ascending key. Swift dictionary iteration order is
///   seeded per process, so unsorted metadata would break cross-run stability.
///
/// ## Stability
///
/// All numbers are rendered with `String(format:)` at fixed precision and negative
/// zero is normalised, so the same input produces byte-identical canonical text in
/// any process. Dates never enter a hash: only elapsed offsets do, which keeps the
/// hash of a workout independent of the absolute wall-clock time it happened at
/// (and keeps absolute timestamps out of anything that gets logged).
public enum WorkoutDetailHashing {

    /// Bump when the canonical text format changes in a way that alters hashes.
    public static let canonicalizationVersion = 1

    // MARK: - Public API

    /// SHA-256 hashes for each family plus a root hash over all of them.
    public struct Hashes: Equatable, Sendable {
        public var route: String
        public var heartRate: String
        public var events: String
        public var activities: String
        /// Hash over the four family hashes in fixed family order, plus identity.
        public var root: String

        public init(route: String, heartRate: String, events: String, activities: String, root: String) {
            self.route = route
            self.heartRate = heartRate
            self.events = events
            self.activities = activities
            self.root = root
        }

        public func hash(for family: WorkoutDetailFamily) -> String {
            switch family {
            case .route: return route
            case .heartRate: return heartRate
            case .events: return events
            case .activities: return activities
            }
        }

        /// Short, non-reversible prefix safe for structured operational logs.
        public func prefix(for family: WorkoutDetailFamily) -> String {
            String(hash(for: family).prefix(8))
        }

        public var rootPrefix: String { String(root.prefix(8)) }
    }

    public static func hashes(for detail: CollectedWorkoutDetail) -> Hashes {
        let route = sha256Hex(canonicalRoute(detail.route))
        let heartRate = sha256Hex(canonicalQuantityStream(detail.heartRate))
        let events = sha256Hex(canonicalEvents(detail.events))
        let activities = sha256Hex(canonicalActivities(detail.activities))

        // The root binds the identity of the workout to its family content, so two
        // different workouts with coincidentally identical streams never collide.
        let rootInput = [
            "v=\(canonicalizationVersion)",
            "schema=\(CollectedWorkoutDetail.schemaVersion)",
            "identity=\(sha256Hex(canonicalIdentity(detail.identity)))",
            "route=\(route)",
            "heart_rate=\(heartRate)",
            "events=\(events)",
            "activities=\(activities)"
        ].joined(separator: "\n")

        return Hashes(
            route: route,
            heartRate: heartRate,
            events: events,
            activities: activities,
            root: sha256Hex(rootInput)
        )
    }

    /// SHA-256 of a UTF-8 string, lowercase hex.
    public static func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }

    /// SHA-256 of raw bytes, lowercase hex.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Keyed SHA-256 (HMAC), lowercase hex. Used by the fixture writer to derive
    /// synthetic identifiers that are stable for a given (input, key) pair and
    /// cannot be reversed to the original identifier without the key.
    public static func keyedHex(_ text: String, key: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(text.utf8),
            using: SymmetricKey(data: Data(key.utf8))
        )
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Canonical text (exposed for tests and the fixture writer)

    public static func canonicalIdentity(_ identity: WorkoutIdentity) -> String {
        // Absolute start/end deliberately excluded; only the duration shape matters.
        var lines = [
            "family=identity",
            "workout_uuid=\(identity.workoutUUID)",
            "sync_identifier=\(optional(identity.syncIdentifier))",
            "sync_version=\(identity.syncVersion.map(String.init) ?? "-")",
            "external_uuid=\(optional(identity.externalUUID))",
            "source_bundle_id=\(identity.sourceBundleIdentifier)",
            "source_name=\(identity.sourceName)",
            "source_version=\(optional(identity.sourceVersion))",
            "source_product_type=\(optional(identity.sourceProductType))",
            "device_manufacturer=\(optional(identity.deviceManufacturer))",
            "device_model=\(optional(identity.deviceModel))",
            "tz_offset_s=\(identity.timeZoneOffsetSeconds.map(String.init) ?? "-")",
            "activity_type=\(identity.activityTypeRawValue)",
            "duration_s=\(num(identity.duration))",
            "span_s=\(num(identity.endDate.timeIntervalSince(identity.startDate)))"
        ]
        lines.append("")
        return lines.joined(separator: "\n")
    }

    public static func canonicalRoute(_ route: WorkoutRouteDetail) -> String {
        var lines = [
            "family=route",
            "availability=\(route.availability.rawValue)",
            "parts=\(route.parts.count)"
        ]
        for part in sortedParts(route.parts) {
            lines.append("part=\(part.partIndex)|\(part.routeUUID)|points=\(part.points.count)")
            for point in sortedPoints(part.points) {
                lines.append(
                    "pt=\(num(point.elapsedOffset))|\(point.ordinal)"
                    + "|\(coord(point.latitude))|\(coord(point.longitude))"
                    + "|\(optionalNum(point.altitude))"
                    + "|\(optionalNum(point.speed))"
                    + "|\(optionalNum(point.course))"
                    + "|\(optionalNum(point.horizontalAccuracy))"
                    + "|\(optionalNum(point.verticalAccuracy))"
                )
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    public static func canonicalQuantityStream(_ stream: WorkoutQuantityStream) -> String {
        var lines = [
            "family=quantity",
            "metric=\(stream.metric)",
            "type=\(stream.quantityTypeIdentifier)",
            "availability=\(stream.availability.rawValue)",
            "top_level_samples=\(stream.topLevelSampleCount)",
            "entries=\(stream.entries.count)"
        ]
        for entry in sortedEntries(stream.entries) {
            lines.append(
                "e=\(num(entry.startElapsedOffset))|\(num(entry.endElapsedOffset))|\(entry.ordinal)"
                + "|\(num(entry.value))|\(entry.unit)"
                + "|\(entry.kind.rawValue)"
                + "|\(entry.sourceKey)"
                + "|series=\(entry.isExpandedFromSeries ? 1 : 0)"
                + "|count=\(entry.parentSeriesCount)"
            )
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    public static func canonicalEvents(_ detail: WorkoutEventsDetail) -> String {
        var lines = [
            "family=events",
            "availability=\(detail.availability.rawValue)",
            "events=\(detail.events.count)"
        ]
        for event in sortedEvents(detail.events) {
            lines.append(
                "ev=\(num(event.startElapsedOffset))|\(num(event.endElapsedOffset))|\(event.ordinal)"
                + "|\(event.typeRawValue)|\(event.typeName)"
                + "|zero=\(event.isZeroDuration ? 1 : 0)"
                + "|meta=\(canonicalMetadata(event.metadata))"
            )
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    public static func canonicalActivities(_ detail: WorkoutActivitiesDetail) -> String {
        var lines = [
            "family=activities",
            "availability=\(detail.availability.rawValue)",
            "os_supported=\(detail.isSupportedOnThisOS ? 1 : 0)",
            "activities=\(detail.activities.count)"
        ]
        for activity in sortedActivities(detail.activities) {
            lines.append(
                "ac=\(activity.position)|\(activity.activityUUID)"
                + "|\(activity.activityTypeRawValue)|\(activity.activityTypeName)"
                + "|\(num(activity.startElapsedOffset))|\(optionalNum(activity.endElapsedOffset))"
                + "|\(num(activity.duration))"
                + "|meta=\(canonicalMetadata(activity.metadata))"
            )
            for stat in activity.statistics.sorted(by: statisticIsBefore) {
                lines.append("  st=\(stat.quantityTypeIdentifier)|\(stat.aggregation)|\(num(stat.value))|\(stat.unit)")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: - Canonical ordering (also used by the fixture writer)

    public static func sortedParts(_ parts: [RoutePart]) -> [RoutePart] {
        parts.sorted { lhs, rhs in
            if lhs.partIndex != rhs.partIndex { return lhs.partIndex < rhs.partIndex }
            return lhs.routeUUID < rhs.routeUUID
        }
    }

    public static func sortedPoints(_ points: [RoutePoint]) -> [RoutePoint] {
        points.sorted { lhs, rhs in
            if lhs.elapsedOffset != rhs.elapsedOffset { return lhs.elapsedOffset < rhs.elapsedOffset }
            return lhs.ordinal < rhs.ordinal
        }
    }

    public static func sortedEntries(_ entries: [QuantityEntry]) -> [QuantityEntry] {
        entries.sorted { lhs, rhs in
            if lhs.startElapsedOffset != rhs.startElapsedOffset {
                return lhs.startElapsedOffset < rhs.startElapsedOffset
            }
            if lhs.endElapsedOffset != rhs.endElapsedOffset {
                return lhs.endElapsedOffset < rhs.endElapsedOffset
            }
            return lhs.ordinal < rhs.ordinal
        }
    }

    public static func sortedEvents(_ events: [WorkoutEventEntry]) -> [WorkoutEventEntry] {
        events.sorted { lhs, rhs in
            if lhs.startElapsedOffset != rhs.startElapsedOffset {
                return lhs.startElapsedOffset < rhs.startElapsedOffset
            }
            if lhs.endElapsedOffset != rhs.endElapsedOffset {
                return lhs.endElapsedOffset < rhs.endElapsedOffset
            }
            if lhs.typeRawValue != rhs.typeRawValue { return lhs.typeRawValue < rhs.typeRawValue }
            return lhs.ordinal < rhs.ordinal
        }
    }

    public static func sortedActivities(_ activities: [WorkoutActivityEntry]) -> [WorkoutActivityEntry] {
        activities.sorted { lhs, rhs in
            if lhs.position != rhs.position { return lhs.position < rhs.position }
            return lhs.activityUUID < rhs.activityUUID
        }
    }

    private static func statisticIsBefore(_ lhs: ActivityStatistic, _ rhs: ActivityStatistic) -> Bool {
        if lhs.quantityTypeIdentifier != rhs.quantityTypeIdentifier {
            return lhs.quantityTypeIdentifier < rhs.quantityTypeIdentifier
        }
        return lhs.aggregation < rhs.aggregation
    }

    // MARK: - Deterministic scalar formatting

    /// Six decimal places is enough for offsets (microseconds) and physiological
    /// values, and is stable across architectures.
    static func num(_ value: Double) -> String {
        guard value.isFinite else { return value.isNaN ? "nan" : (value < 0 ? "-inf" : "inf") }
        let normalised = value == 0 ? 0 : value
        return String(format: "%.6f", normalised)
    }

    /// Coordinates keep nine decimal places — the acceptance gate requires at least
    /// six to survive, and rounding at hash time would hide precision loss.
    static func coord(_ value: Double) -> String {
        guard value.isFinite else { return value.isNaN ? "nan" : (value < 0 ? "-inf" : "inf") }
        let normalised = value == 0 ? 0 : value
        return String(format: "%.9f", normalised)
    }

    static func optionalNum(_ value: Double?) -> String {
        guard let value else { return "-" }
        return num(value)
    }

    private static func optional(_ value: String?) -> String {
        value ?? "-"
    }

    static func canonicalMetadata(_ metadata: [String: String]) -> String {
        guard !metadata.isEmpty else { return "-" }
        return metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ";")
    }
}
