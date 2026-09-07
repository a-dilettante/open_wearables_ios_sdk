import Foundation

// MARK: - Availability
//
// Apple intentionally does not reveal whether a HealthKit read was denied: denied
// data is indistinguishable from missing data. There is therefore deliberately no
// `permissionDenied` case here and there must never be one. An unreadable family
// reports `.notAvailableOrNotAuthorized`.

/// Privacy-safe availability of one collected workout-detail family.
public enum WorkoutDetailAvailability: String, Codable, Sendable, CaseIterable {
    /// The family was read and is believed complete for what the source stored.
    case available
    /// Some of the family was read, but a part is known to be missing or truncated.
    case partial
    /// Nothing has been read yet, or the source may still write it (late routes).
    case pendingEnrichment = "pending_enrichment"
    /// HealthKit returned nothing. This covers "the source never saved it" and
    /// "read access is not granted"; Apple makes those two indistinguishable.
    case notAvailableOrNotAuthorized = "not_available_or_not_authorized"
    /// The family was read but failed validation (non-finite, out of bounds, …).
    case invalid
}

/// The four workout-owned detail families collected in Phase 0.
public enum WorkoutDetailFamily: String, Codable, Sendable, CaseIterable {
    case route
    case heartRate = "heart_rate"
    case events
    case activities
}

// MARK: - Identity

/// Workout identity and provenance, preserved exactly as HealthKit reports it.
///
/// The logical identity is `(sourceBundleIdentifier, syncIdentifier)` when a
/// trustworthy sync identifier is present, otherwise `workoutUUID`. Start/end
/// time is never an identity.
public struct WorkoutIdentity: Equatable, Sendable {
    /// `HKWorkout.uuid` — always preserved as the current HealthKit object ID.
    public var workoutUUID: String
    /// `HKMetadataKeySyncIdentifier`, when the source wrote one.
    public var syncIdentifier: String?
    /// `HKMetadataKeySyncVersion`. Only orderable within the same sync identifier.
    public var syncVersion: Int?
    /// `HKMetadataKeyExternalUUID`, when the source wrote one.
    public var externalUUID: String?

    public var sourceBundleIdentifier: String
    public var sourceName: String
    public var sourceVersion: String?
    /// `HKSourceRevision.productType` (e.g. "Watch6,1"). Provenance, not a content revision.
    public var sourceProductType: String?
    public var sourceOperatingSystemVersion: String?

    public var deviceName: String?
    public var deviceManufacturer: String?
    public var deviceModel: String?
    public var deviceHardwareVersion: String?
    public var deviceSoftwareVersion: String?

    /// `HKMetadataKeyTimeZone` identifier, when present.
    public var timeZoneIdentifier: String?
    /// Original offset from GMT in seconds at the workout start.
    public var timeZoneOffsetSeconds: Int?

    public var activityTypeRawValue: UInt
    public var activityTypeName: String

    public var startDate: Date
    public var endDate: Date
    /// `HKWorkout.duration` — excludes paused time, so it is not `endDate - startDate`.
    public var duration: TimeInterval

    public init(
        workoutUUID: String,
        syncIdentifier: String? = nil,
        syncVersion: Int? = nil,
        externalUUID: String? = nil,
        sourceBundleIdentifier: String,
        sourceName: String,
        sourceVersion: String? = nil,
        sourceProductType: String? = nil,
        sourceOperatingSystemVersion: String? = nil,
        deviceName: String? = nil,
        deviceManufacturer: String? = nil,
        deviceModel: String? = nil,
        deviceHardwareVersion: String? = nil,
        deviceSoftwareVersion: String? = nil,
        timeZoneIdentifier: String? = nil,
        timeZoneOffsetSeconds: Int? = nil,
        activityTypeRawValue: UInt,
        activityTypeName: String,
        startDate: Date,
        endDate: Date,
        duration: TimeInterval
    ) {
        self.workoutUUID = workoutUUID
        self.syncIdentifier = syncIdentifier
        self.syncVersion = syncVersion
        self.externalUUID = externalUUID
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.sourceName = sourceName
        self.sourceVersion = sourceVersion
        self.sourceProductType = sourceProductType
        self.sourceOperatingSystemVersion = sourceOperatingSystemVersion
        self.deviceName = deviceName
        self.deviceManufacturer = deviceManufacturer
        self.deviceModel = deviceModel
        self.deviceHardwareVersion = deviceHardwareVersion
        self.deviceSoftwareVersion = deviceSoftwareVersion
        self.timeZoneIdentifier = timeZoneIdentifier
        self.timeZoneOffsetSeconds = timeZoneOffsetSeconds
        self.activityTypeRawValue = activityTypeRawValue
        self.activityTypeName = activityTypeName
        self.startDate = startDate
        self.endDate = endDate
        self.duration = duration
    }
}

// MARK: - Route

/// One location HealthKit returned for a workout route, at source fidelity.
///
/// Optional fields stay optional: CoreLocation signals "unknown" with a negative
/// accuracy or a negative course, and those are mapped to `nil` rather than being
/// kept as fake measurements or rewritten to zero.
public struct RoutePoint: Equatable, Sendable {
    public var timestamp: Date
    /// Seconds from the workout start. May be negative if the source wrote a
    /// location slightly before `HKWorkout.startDate`; that is preserved, not clamped.
    public var elapsedOffset: TimeInterval
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?
    /// Metres per second, when the source recorded a valid speed.
    public var speed: Double?
    /// Degrees from true north, when the source recorded a valid course.
    public var course: Double?
    public var horizontalAccuracy: Double?
    public var verticalAccuracy: Double?
    /// Arrival order within the route part; disambiguates equal timestamps.
    public var ordinal: Int

    public init(
        timestamp: Date,
        elapsedOffset: TimeInterval,
        latitude: Double,
        longitude: Double,
        altitude: Double? = nil,
        speed: Double? = nil,
        course: Double? = nil,
        horizontalAccuracy: Double? = nil,
        verticalAccuracy: Double? = nil,
        ordinal: Int
    ) {
        self.timestamp = timestamp
        self.elapsedOffset = elapsedOffset
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.speed = speed
        self.course = course
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.ordinal = ordinal
    }
}

/// One `HKWorkoutRoute` object. A workout can own several; never assume one.
public struct RoutePart: Equatable, Sendable {
    /// Source `HKWorkoutRoute.uuid`, preserved so a tombstone can find its owner.
    public var routeUUID: String
    /// Order of this route object among the workout's routes.
    public var partIndex: Int
    /// How many `HKWorkoutRouteQuery` callbacks this part needed. Batch size is
    /// opaque and unpublished, so this is observed, never assumed.
    public var batchCount: Int
    public var points: [RoutePoint]

    public init(routeUUID: String, partIndex: Int, batchCount: Int, points: [RoutePoint]) {
        self.routeUUID = routeUUID
        self.partIndex = partIndex
        self.batchCount = batchCount
        self.points = points
    }
}

public struct WorkoutRouteDetail: Equatable, Sendable {
    public var availability: WorkoutDetailAvailability
    public var parts: [RoutePart]

    public var pointCount: Int { parts.reduce(0) { $0 + $1.points.count } }

    public init(availability: WorkoutDetailAvailability, parts: [RoutePart] = []) {
        self.availability = availability
        self.parts = parts
    }
}

// MARK: - Quantity stream (heart rate first)

/// Whether an entry is an instant reading or a span HealthKit reported as one value.
public enum QuantityEntryKind: String, Codable, Sendable {
    /// `startDate == endDate`.
    case point
    /// `startDate < endDate` — a coalesced/condensed interval. Its value applies to
    /// the whole span; do not fabricate point timestamps inside it.
    case interval
}

/// One heart-rate (or later, any quantity) entry on its own independent time axis.
public struct QuantityEntry: Equatable, Sendable {
    public var startDate: Date
    public var endDate: Date
    public var startElapsedOffset: TimeInterval
    public var endElapsedOffset: TimeInterval
    public var value: Double
    /// Canonical unit string, converted exactly once at read time (e.g. "count/min").
    public var unit: String
    /// `HKSample.uuid` of the owning top-level sample. Series entries expanded from
    /// one condensed sample all share it, which is correct: they have one HK object.
    public var sampleUUID: String?
    /// Stable per-source key so watch/strap/phone samples are never silently merged.
    public var sourceKey: String
    public var sourceBundleIdentifier: String?
    public var sourceName: String?
    public var sourceVersion: String?
    public var deviceManufacturer: String?
    public var deviceModel: String?
    public var deviceProductType: String?
    public var kind: QuantityEntryKind
    /// True when this entry came out of `HKQuantitySeriesSampleQuery` rather than
    /// from the top-level sample itself.
    public var isExpandedFromSeries: Bool
    /// `HKQuantitySample.count` of the owning sample. `> 1` means it was condensed.
    public var parentSeriesCount: Int
    /// Order within equal `startElapsedOffset` values.
    public var ordinal: Int

    public init(
        startDate: Date,
        endDate: Date,
        startElapsedOffset: TimeInterval,
        endElapsedOffset: TimeInterval,
        value: Double,
        unit: String,
        sampleUUID: String? = nil,
        sourceKey: String,
        sourceBundleIdentifier: String? = nil,
        sourceName: String? = nil,
        sourceVersion: String? = nil,
        deviceManufacturer: String? = nil,
        deviceModel: String? = nil,
        deviceProductType: String? = nil,
        kind: QuantityEntryKind,
        isExpandedFromSeries: Bool = false,
        parentSeriesCount: Int = 1,
        ordinal: Int
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.startElapsedOffset = startElapsedOffset
        self.endElapsedOffset = endElapsedOffset
        self.value = value
        self.unit = unit
        self.sampleUUID = sampleUUID
        self.sourceKey = sourceKey
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.sourceName = sourceName
        self.sourceVersion = sourceVersion
        self.deviceManufacturer = deviceManufacturer
        self.deviceModel = deviceModel
        self.deviceProductType = deviceProductType
        self.kind = kind
        self.isExpandedFromSeries = isExpandedFromSeries
        self.parentSeriesCount = parentSeriesCount
        self.ordinal = ordinal
    }
}

public struct WorkoutQuantityStream: Equatable, Sendable {
    public var availability: WorkoutDetailAvailability
    /// Canonical metric name, e.g. "heart_rate".
    public var metric: String
    /// HealthKit type identifier the entries were read from.
    public var quantityTypeIdentifier: String
    public var entries: [QuantityEntry]
    /// Number of top-level HealthKit samples the entries were expanded from.
    /// Outer sample count never equals expanded entry count.
    public var topLevelSampleCount: Int

    public init(
        availability: WorkoutDetailAvailability,
        metric: String,
        quantityTypeIdentifier: String,
        entries: [QuantityEntry] = [],
        topLevelSampleCount: Int = 0
    ) {
        self.availability = availability
        self.metric = metric
        self.quantityTypeIdentifier = quantityTypeIdentifier
        self.entries = entries
        self.topLevelSampleCount = topLevelSampleCount
    }
}

// MARK: - Events

/// One `HKWorkoutEvent`, with its exact native type preserved.
///
/// Pause, resume, automatic pause, automatic resume, lap, segment, and marker stay
/// distinct. Legacy zero-duration lap markers are kept as-is and never widened into
/// synthetic intervals.
public struct WorkoutEventEntry: Equatable, Sendable {
    /// `HKWorkoutEventType.rawValue`, preserved even if this SDK has no name for it.
    public var typeRawValue: Int
    /// Stable label for the raw value, or "unknown_<raw>" for a future case.
    public var typeName: String
    public var startDate: Date
    public var endDate: Date
    public var startElapsedOffset: TimeInterval
    public var endElapsedOffset: TimeInterval
    public var metadata: [String: String]
    public var ordinal: Int

    /// True for legacy lap markers HealthKit reports with no duration.
    public var isZeroDuration: Bool { endDate == startDate }

    public init(
        typeRawValue: Int,
        typeName: String,
        startDate: Date,
        endDate: Date,
        startElapsedOffset: TimeInterval,
        endElapsedOffset: TimeInterval,
        metadata: [String: String] = [:],
        ordinal: Int
    ) {
        self.typeRawValue = typeRawValue
        self.typeName = typeName
        self.startDate = startDate
        self.endDate = endDate
        self.startElapsedOffset = startElapsedOffset
        self.endElapsedOffset = endElapsedOffset
        self.metadata = metadata
        self.ordinal = ordinal
    }
}

public struct WorkoutEventsDetail: Equatable, Sendable {
    public var availability: WorkoutDetailAvailability
    public var events: [WorkoutEventEntry]

    public init(availability: WorkoutDetailAvailability, events: [WorkoutEventEntry] = []) {
        self.availability = availability
        self.events = events
    }
}

// MARK: - Activities (iOS 16+)

/// One statistic HealthKit associates with a workout activity.
public struct ActivityStatistic: Equatable, Sendable {
    public var quantityTypeIdentifier: String
    /// "sum", "average", "minimum", or "maximum".
    public var aggregation: String
    public var value: Double
    public var unit: String

    public init(quantityTypeIdentifier: String, aggregation: String, value: Double, unit: String) {
        self.quantityTypeIdentifier = quantityTypeIdentifier
        self.aggregation = aggregation
        self.value = value
        self.unit = unit
    }
}

/// One `HKWorkoutActivity`. Not a lap and not a segment — stored separately.
public struct WorkoutActivityEntry: Equatable, Sendable {
    /// `HKWorkoutActivity.uuid` on iOS 16+.
    public var activityUUID: String
    /// Ordered position within the workout, as HealthKit returned it.
    public var position: Int
    public var activityTypeRawValue: UInt
    public var activityTypeName: String
    public var startDate: Date
    /// `nil` while an activity is still open (HealthKit allows it).
    public var endDate: Date?
    public var startElapsedOffset: TimeInterval
    public var endElapsedOffset: TimeInterval?
    public var duration: TimeInterval
    public var statistics: [ActivityStatistic]
    public var metadata: [String: String]

    public init(
        activityUUID: String,
        position: Int,
        activityTypeRawValue: UInt,
        activityTypeName: String,
        startDate: Date,
        endDate: Date? = nil,
        startElapsedOffset: TimeInterval,
        endElapsedOffset: TimeInterval? = nil,
        duration: TimeInterval,
        statistics: [ActivityStatistic] = [],
        metadata: [String: String] = [:]
    ) {
        self.activityUUID = activityUUID
        self.position = position
        self.activityTypeRawValue = activityTypeRawValue
        self.activityTypeName = activityTypeName
        self.startDate = startDate
        self.endDate = endDate
        self.startElapsedOffset = startElapsedOffset
        self.endElapsedOffset = endElapsedOffset
        self.duration = duration
        self.statistics = statistics
        self.metadata = metadata
    }
}

public struct WorkoutActivitiesDetail: Equatable, Sendable {
    public var availability: WorkoutDetailAvailability
    public var activities: [WorkoutActivityEntry]
    /// False on iOS 15, where `HKWorkoutActivity` does not exist. That is a platform
    /// fact, not a permission or data problem.
    public var isSupportedOnThisOS: Bool

    public init(
        availability: WorkoutDetailAvailability,
        activities: [WorkoutActivityEntry] = [],
        isSupportedOnThisOS: Bool
    ) {
        self.availability = availability
        self.activities = activities
        self.isSupportedOnThisOS = isSupportedOnThisOS
    }
}

// MARK: - Collected root

/// Everything the Phase 0 reader collected for exactly one HealthKit workout.
///
/// Each family carries its own availability and its own time axis. A missing route
/// never invalidates heart rate, and vice versa.
public struct CollectedWorkoutDetail: Equatable, Sendable {
    /// Bump when the shape of the collected model changes.
    public static let schemaVersion = 1

    public var identity: WorkoutIdentity
    public var route: WorkoutRouteDetail
    public var heartRate: WorkoutQuantityStream
    public var events: WorkoutEventsDetail
    public var activities: WorkoutActivitiesDetail

    public init(
        identity: WorkoutIdentity,
        route: WorkoutRouteDetail,
        heartRate: WorkoutQuantityStream,
        events: WorkoutEventsDetail,
        activities: WorkoutActivitiesDetail
    ) {
        self.identity = identity
        self.route = route
        self.heartRate = heartRate
        self.events = events
        self.activities = activities
    }

    public func availability(of family: WorkoutDetailFamily) -> WorkoutDetailAvailability {
        switch family {
        case .route: return route.availability
        case .heartRate: return heartRate.availability
        case .events: return events.availability
        case .activities: return activities.availability
        }
    }
}
