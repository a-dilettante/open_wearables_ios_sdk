import Foundation
import HealthKit
import CoreLocation

/// Errors the Phase 0 reader can surface. None of them distinguish "denied" from
/// "absent" — Apple does not expose that difference and this SDK must not invent it.
public enum WorkoutDetailReaderError: Error {
    case healthDataUnavailable
    case workoutNotFound
    /// HealthKit refused the query (locked device, protected data, internal error).
    case queryFailed(String)
}

// MARK: - Pure mapping layer
//
// Everything here is a pure function over Foundation values. It is fully testable
// without HealthKit entitlements; the HealthKit-touching code below is a thin
// adapter that feeds these functions.

public enum WorkoutDetailMapping {

    /// Seconds from the workout start. Never clamped: a source may write a location
    /// or sample marginally outside the workout bounds and that is real information.
    public static func elapsedOffset(of date: Date, from start: Date) -> TimeInterval {
        date.timeIntervalSince(start)
    }

    /// A span HealthKit reports with `start == end` is an instant reading; anything
    /// wider is a coalesced/condensed interval whose value covers the whole span.
    public static func entryKind(start: Date, end: Date) -> QuantityEntryKind {
        end > start ? .interval : .point
    }

    /// CoreLocation reports "unknown" with a negative accuracy, and an invalid
    /// course/speed as a negative number. Those become `nil` rather than being kept
    /// as fake measurements or silently rewritten to zero.
    public static func validMeasurement(_ value: Double) -> Double? {
        guard value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// Altitude is signed (below sea level is legal), so only finiteness is checked.
    public static func validSignedMeasurement(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        return value
    }

    /// Stable label for `HKWorkoutEventType.rawValue`. Unknown future raw values keep
    /// their number so a new native type is never flattened into an existing one.
    public static func eventTypeName(rawValue: Int) -> String {
        switch rawValue {
        case 1: return "pause"
        case 2: return "resume"
        case 3: return "lap"
        case 4: return "marker"
        case 5: return "motion_paused"
        case 6: return "motion_resumed"
        case 7: return "segment"
        case 8: return "pause_or_resume_request"
        default: return "unknown_\(rawValue)"
        }
    }

    /// Derives family availability from what HealthKit actually returned.
    ///
    /// - `isReadable == false` means the query itself failed, which is `.invalid`.
    /// - An empty family is `.notAvailableOrNotAuthorized`: the source may never have
    ///   saved it, or read access may be missing. Apple makes those indistinguishable,
    ///   so this SDK must not claim a permission outcome.
    /// - `isComplete == false` marks a family whose collection was cut short.
    public static func availability(
        isReadable: Bool,
        count: Int,
        isComplete: Bool = true
    ) -> WorkoutDetailAvailability {
        guard isReadable else { return .invalid }
        guard count > 0 else { return .notAvailableOrNotAuthorized }
        return isComplete ? .available : .partial
    }

    /// Per-source key so watch, chest strap, phone, and third-party samples are never
    /// silently merged into one stream.
    public static func sourceKey(bundleIdentifier: String, productType: String?, deviceModel: String?) -> String {
        [bundleIdentifier, productType ?? "-", deviceModel ?? "-"].joined(separator: "|")
    }
}

// MARK: - HealthKit adapter

/// Reads one workout's owned detail out of HealthKit at source fidelity.
///
/// Nothing here resamples, downsamples, interpolates, or assumes a cadence. Every
/// family is queried on its own independent time axis and reported with its own
/// availability, so a missing route never suppresses heart rate.
/// Safe to hand across concurrency domains: the only stored property is an
/// immutable `HKHealthStore`, and HealthKit permits executing and stopping queries
/// from any thread.
public final class WorkoutDetailReader: @unchecked Sendable {

    private let healthStore: HKHealthStore

    public init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    // MARK: Workout lookup

    /// Fetches exactly one workout by its HealthKit object UUID.
    public func fetchWorkout(uuid: UUID) async throws -> HKWorkout {
        guard HKHealthStore.isHealthDataAvailable() else { throw WorkoutDetailReaderError.healthDataUnavailable }

        let samples = try await runSampleQuery(
            sampleType: HKObjectType.workoutType(),
            predicate: HKQuery.predicateForObject(with: uuid),
            limit: 1,
            sortDescriptors: nil
        )
        guard let workout = samples.first as? HKWorkout else { throw WorkoutDetailReaderError.workoutNotFound }
        return workout
    }

    /// Most-recent-first workouts, for picking one to probe on device.
    public func recentWorkouts(limit: Int = 25) async throws -> [HKWorkout] {
        guard HKHealthStore.isHealthDataAvailable() else { throw WorkoutDetailReaderError.healthDataUnavailable }

        let samples = try await runSampleQuery(
            sampleType: HKObjectType.workoutType(),
            predicate: nil,
            limit: limit,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
        )
        return samples.compactMap { $0 as? HKWorkout }
    }

    // MARK: Full collection

    /// Collects identity, route, heart rate, events, and activities for one workout.
    ///
    /// Each family is collected independently and a failure in one is recorded as
    /// that family's availability rather than thrown, so partial detail still
    /// produces a usable result.
    public func collectDetail(for workout: HKWorkout) async -> CollectedWorkoutDetail {
        let identity = makeIdentity(workout)
        let route = await collectRoute(for: workout)
        let heartRate = await collectHeartRate(for: workout)
        let events = collectEvents(for: workout)
        let activities = collectActivities(for: workout)
        return CollectedWorkoutDetail(
            identity: identity,
            route: route,
            heartRate: heartRate,
            events: events,
            activities: activities
        )
    }

    /// Minimal owned-HR mode. It performs only the exact workout-owned heart-rate
    /// query and never asks HealthKit for route, event, or activity data.
    public func collectHeartRateOnly(for workout: HKWorkout) async -> CollectedWorkoutDetail {
        CollectedWorkoutDetail(
            identity: makeIdentity(workout),
            route: WorkoutRouteDetail(availability: .notAvailableOrNotAuthorized),
            heartRate: await collectHeartRate(for: workout),
            events: WorkoutEventsDetail(availability: .notAvailableOrNotAuthorized),
            activities: WorkoutActivitiesDetail(availability: .notAvailableOrNotAuthorized, isSupportedOnThisOS: false)
        )
    }

    // MARK: Identity

    func makeIdentity(_ workout: HKWorkout) -> WorkoutIdentity {
        let metadata = workout.metadata ?? [:]
        let revision = workout.sourceRevision
        let osVersion = revision.operatingSystemVersion

        var timeZoneIdentifier: String?
        var timeZoneOffsetSeconds: Int?
        if let tzName = metadata[HKMetadataKeyTimeZone] as? String, let tz = TimeZone(identifier: tzName) {
            timeZoneIdentifier = tzName
            timeZoneOffsetSeconds = tz.secondsFromGMT(for: workout.startDate)
        }

        return WorkoutIdentity(
            workoutUUID: workout.uuid.uuidString,
            syncIdentifier: metadata[HKMetadataKeySyncIdentifier] as? String,
            syncVersion: (metadata[HKMetadataKeySyncVersion] as? NSNumber)?.intValue,
            externalUUID: metadata[HKMetadataKeyExternalUUID] as? String,
            sourceBundleIdentifier: revision.source.bundleIdentifier,
            sourceName: revision.source.name,
            sourceVersion: revision.version,
            sourceProductType: revision.productType,
            sourceOperatingSystemVersion: "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)",
            deviceName: workout.device?.name,
            deviceManufacturer: workout.device?.manufacturer,
            deviceModel: workout.device?.model,
            deviceHardwareVersion: workout.device?.hardwareVersion,
            deviceSoftwareVersion: workout.device?.softwareVersion,
            timeZoneIdentifier: timeZoneIdentifier,
            timeZoneOffsetSeconds: timeZoneOffsetSeconds,
            activityTypeRawValue: workout.workoutActivityType.rawValue,
            activityTypeName: OpenWearablesHealthSDK.shared._workoutTypeString(workout.workoutActivityType),
            startDate: workout.startDate,
            endDate: workout.endDate,
            duration: workout.duration
        )
    }

    // MARK: Route

    /// Reads every `HKWorkoutRoute` associated with the workout, and every batch of
    /// every route, until `done == true`.
    ///
    /// A workout can own several route objects and `HKWorkoutRouteQuery` delivers an
    /// unpublished number of opaque batches, so neither is ever assumed to be one.
    func collectRoute(for workout: HKWorkout) async -> WorkoutRouteDetail {
        let routeObjects: [HKWorkoutRoute]
        do {
            let samples = try await runSampleQuery(
                sampleType: HKSeriesType.workoutRoute(),
                // Exact workout association. A time-overlapping route is NOT this
                // workout's route, so a start/end predicate would be wrong here.
                predicate: HKQuery.predicateForObjects(from: workout),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            )
            routeObjects = samples.compactMap { $0 as? HKWorkoutRoute }
        } catch {
            return WorkoutRouteDetail(availability: .invalid)
        }

        guard !routeObjects.isEmpty else {
            // Could be an indoor workout, a source that saved no route, a route that
            // has not been written yet, or missing authorization — all opaque.
            return WorkoutRouteDetail(availability: .notAvailableOrNotAuthorized)
        }

        var parts: [RoutePart] = []
        var allPartsComplete = true

        for (index, routeObject) in routeObjects.enumerated() {
            do {
                let (locations, batchCount) = try await readAllRouteBatches(routeObject)
                var ordinal = 0
                let points: [RoutePoint] = locations.map { location in
                    defer { ordinal += 1 }
                    return RoutePoint(
                        timestamp: location.timestamp,
                        elapsedOffset: WorkoutDetailMapping.elapsedOffset(of: location.timestamp, from: workout.startDate),
                        latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude,
                        altitude: WorkoutDetailMapping.validSignedMeasurement(location.altitude),
                        speed: WorkoutDetailMapping.validMeasurement(location.speed),
                        course: WorkoutDetailMapping.validMeasurement(location.course),
                        horizontalAccuracy: WorkoutDetailMapping.validMeasurement(location.horizontalAccuracy),
                        verticalAccuracy: WorkoutDetailMapping.validMeasurement(location.verticalAccuracy),
                        ordinal: ordinal
                    )
                }
                parts.append(RoutePart(
                    routeUUID: routeObject.uuid.uuidString,
                    partIndex: index,
                    batchCount: batchCount,
                    points: points
                ))
            } catch {
                // One unreadable route part must not discard the parts that did read.
                allPartsComplete = false
            }
        }

        let pointCount = parts.reduce(0) { $0 + $1.points.count }
        return WorkoutRouteDetail(
            availability: WorkoutDetailMapping.availability(
                isReadable: true,
                count: pointCount,
                isComplete: allPartsComplete
            ),
            parts: parts
        )
    }

    /// Drains one `HKWorkoutRouteQuery` completely, returning the locations and how
    /// many batches HealthKit used to deliver them.
    private func readAllRouteBatches(_ route: HKWorkoutRoute) async throws -> ([CLLocation], Int) {
        try await withCheckedThrowingContinuation { continuation in
            var collected: [CLLocation] = []
            var batchCount = 0
            var hasResumed = false

            let query = HKWorkoutRouteQuery(route: route) { query, locations, done, error in
                if hasResumed { return }

                if let error {
                    hasResumed = true
                    self.healthStore.stop(query)
                    continuation.resume(throwing: WorkoutDetailReaderError.queryFailed(error.localizedDescription))
                    return
                }

                if let locations, !locations.isEmpty {
                    batchCount += 1
                    collected.append(contentsOf: locations)
                }

                // Only `done` ends the route. Returning after the first batch would
                // silently truncate long routes.
                if done {
                    hasResumed = true
                    continuation.resume(returning: (collected, batchCount))
                }
            }
            healthStore.execute(query)
        }
    }

    // MARK: Heart rate

    /// Reads heart-rate samples associated with the exact workout, expanding any
    /// condensed series sample into its constituent entries.
    func collectHeartRate(for workout: HKWorkout) async -> WorkoutQuantityStream {
        guard let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate) else {
            return WorkoutQuantityStream(
                availability: .invalid,
                metric: "heart_rate",
                quantityTypeIdentifier: HKQuantityTypeIdentifier.heartRate.rawValue
            )
        }

        let bpm = HKUnit.count().unitDivided(by: .minute())
        let unitString = "count/min"
        let samples: [HKQuantitySample]
        do {
            let raw = try await runSampleQuery(
                sampleType: heartRateType,
                // Exact workout association — NEVER a start/end time predicate. An
                // ambient heart-rate sample that merely overlaps the workout window
                // is not owned by the workout.
                predicate: HKQuery.predicateForObjects(from: workout),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            )
            samples = raw.compactMap { $0 as? HKQuantitySample }
        } catch {
            return WorkoutQuantityStream(
                availability: .invalid,
                metric: "heart_rate",
                quantityTypeIdentifier: heartRateType.identifier
            )
        }

        var entries: [QuantityEntry] = []
        var ordinal = 0
        var allExpansionsComplete = true

        for sample in samples {
            let sourceKey = WorkoutDetailMapping.sourceKey(
                bundleIdentifier: sample.sourceRevision.source.bundleIdentifier,
                productType: sample.sourceRevision.productType,
                deviceModel: sample.device?.model
            )
            let sourceBundleIdentifier = sample.sourceRevision.source.bundleIdentifier
            let sourceName = sample.sourceRevision.source.name
            let sourceVersion = sample.sourceRevision.version
            let deviceManufacturer = sample.device?.manufacturer
            let deviceModel = sample.device?.model
            let deviceProductType = sample.sourceRevision.productType

            // `count > 1` means HealthKit condensed this into a quantity series.
            if sample.count > 1 {
                do {
                    let seriesEntries = try await expandSeries(
                        sample: sample,
                        quantityType: heartRateType,
                        unit: bpm,
                        unitString: unitString,
                        sourceKey: sourceKey,
                        sourceBundleIdentifier: sourceBundleIdentifier,
                        sourceName: sourceName,
                        sourceVersion: sourceVersion,
                        deviceManufacturer: deviceManufacturer,
                        deviceModel: deviceModel,
                        deviceProductType: deviceProductType,
                        workoutStart: workout.startDate,
                        startingOrdinal: ordinal
                    )
                    ordinal += seriesEntries.count
                    entries.append(contentsOf: seriesEntries)
                    continue
                } catch {
                    // Fall through and keep the aggregate entry rather than dropping
                    // the sample entirely, but flag the stream as incomplete.
                    allExpansionsComplete = false
                }
            }

            entries.append(QuantityEntry(
                startDate: sample.startDate,
                endDate: sample.endDate,
                startElapsedOffset: WorkoutDetailMapping.elapsedOffset(of: sample.startDate, from: workout.startDate),
                endElapsedOffset: WorkoutDetailMapping.elapsedOffset(of: sample.endDate, from: workout.startDate),
                value: sample.quantity.doubleValue(for: bpm),
                unit: unitString,
                sampleUUID: sample.uuid.uuidString,
                sourceKey: sourceKey,
                sourceBundleIdentifier: sourceBundleIdentifier,
                sourceName: sourceName,
                sourceVersion: sourceVersion,
                deviceManufacturer: deviceManufacturer,
                deviceModel: deviceModel,
                deviceProductType: deviceProductType,
                kind: WorkoutDetailMapping.entryKind(start: sample.startDate, end: sample.endDate),
                isExpandedFromSeries: false,
                parentSeriesCount: sample.count,
                ordinal: ordinal
            ))
            ordinal += 1
        }

        return WorkoutQuantityStream(
            availability: WorkoutDetailMapping.availability(
                isReadable: true,
                count: entries.count,
                isComplete: allExpansionsComplete
            ),
            metric: "heart_rate",
            quantityTypeIdentifier: heartRateType.identifier,
            entries: entries,
            topLevelSampleCount: samples.count
        )
    }

    /// Expands one condensed `HKQuantitySample` via `HKQuantitySeriesSampleQuery`.
    ///
    /// HealthKit hands back a `DateInterval` per entry. When that interval has a
    /// duration the entry stays an interval: its value applies across the span and
    /// inventing point timestamps inside it would fabricate data.
    private func expandSeries(
        sample: HKQuantitySample,
        quantityType: HKQuantityType,
        unit: HKUnit,
        unitString: String,
        sourceKey: String,
        sourceBundleIdentifier: String?,
        sourceName: String?,
        sourceVersion: String?,
        deviceManufacturer: String?,
        deviceModel: String?,
        deviceProductType: String?,
        workoutStart: Date,
        startingOrdinal: Int
    ) async throws -> [QuantityEntry] {
        try await withCheckedThrowingContinuation { continuation in
            var entries: [QuantityEntry] = []
            var ordinal = startingOrdinal
            var hasResumed = false

            let query = HKQuantitySeriesSampleQuery(
                quantityType: quantityType,
                predicate: HKQuery.predicateForObject(with: sample.uuid)
            ) { query, quantity, dateInterval, _, done, error in
                if hasResumed { return }

                if let error {
                    hasResumed = true
                    self.healthStore.stop(query)
                    continuation.resume(throwing: WorkoutDetailReaderError.queryFailed(error.localizedDescription))
                    return
                }

                if let quantity, let dateInterval {
                    entries.append(QuantityEntry(
                        startDate: dateInterval.start,
                        endDate: dateInterval.end,
                        startElapsedOffset: WorkoutDetailMapping.elapsedOffset(of: dateInterval.start, from: workoutStart),
                        endElapsedOffset: WorkoutDetailMapping.elapsedOffset(of: dateInterval.end, from: workoutStart),
                        value: quantity.doubleValue(for: unit),
                        unit: unitString,
                        sampleUUID: sample.uuid.uuidString,
                        sourceKey: sourceKey,
                        sourceBundleIdentifier: sourceBundleIdentifier,
                        sourceName: sourceName,
                        sourceVersion: sourceVersion,
                        deviceManufacturer: deviceManufacturer,
                        deviceModel: deviceModel,
                        deviceProductType: deviceProductType,
                        kind: WorkoutDetailMapping.entryKind(start: dateInterval.start, end: dateInterval.end),
                        isExpandedFromSeries: true,
                        parentSeriesCount: sample.count,
                        ordinal: ordinal
                    ))
                    ordinal += 1
                }

                if done {
                    hasResumed = true
                    continuation.resume(returning: entries)
                }
            }
            healthStore.execute(query)
        }
    }

    // MARK: Events

    /// Reads `HKWorkout.workoutEvents`, preserving each exact native type.
    ///
    /// Laps, segments, markers, pauses, resumes, and automatic pauses/resumes stay
    /// distinct, and a legacy zero-duration lap keeps its zero duration.
    func collectEvents(for workout: HKWorkout) -> WorkoutEventsDetail {
        guard let nativeEvents = workout.workoutEvents, !nativeEvents.isEmpty else {
            return WorkoutEventsDetail(availability: .notAvailableOrNotAuthorized)
        }

        var ordinal = 0
        let events: [WorkoutEventEntry] = nativeEvents.map { event in
            defer { ordinal += 1 }
            var metadata: [String: String] = [:]
            for (key, value) in event.metadata ?? [:] {
                metadata[key] = "\(value)"
            }
            return WorkoutEventEntry(
                typeRawValue: event.type.rawValue,
                typeName: WorkoutDetailMapping.eventTypeName(rawValue: event.type.rawValue),
                startDate: event.dateInterval.start,
                endDate: event.dateInterval.end,
                startElapsedOffset: WorkoutDetailMapping.elapsedOffset(of: event.dateInterval.start, from: workout.startDate),
                endElapsedOffset: WorkoutDetailMapping.elapsedOffset(of: event.dateInterval.end, from: workout.startDate),
                metadata: metadata,
                ordinal: ordinal
            )
        }

        return WorkoutEventsDetail(
            availability: WorkoutDetailMapping.availability(isReadable: true, count: events.count),
            events: events
        )
    }

    // MARK: Activities (iOS 16+)

    /// Reads `HKWorkout.workoutActivities`, which only exists on iOS 16 and later.
    ///
    /// On iOS 15 this reports `isSupportedOnThisOS == false`: that is a platform
    /// fact, not missing data and not a permission outcome.
    func collectActivities(for workout: HKWorkout) -> WorkoutActivitiesDetail {
        guard #available(iOS 16.0, *) else {
            return WorkoutActivitiesDetail(
                availability: .notAvailableOrNotAuthorized,
                isSupportedOnThisOS: false
            )
        }

        let nativeActivities = workout.workoutActivities
        guard !nativeActivities.isEmpty else {
            return WorkoutActivitiesDetail(
                availability: .notAvailableOrNotAuthorized,
                isSupportedOnThisOS: true
            )
        }

        var position = 0
        let activities: [WorkoutActivityEntry] = nativeActivities.map { activity in
            defer { position += 1 }
            var metadata: [String: String] = [:]
            for (key, value) in activity.metadata ?? [:] {
                metadata[key] = "\(value)"
            }
            return WorkoutActivityEntry(
                activityUUID: activity.uuid.uuidString,
                position: position,
                activityTypeRawValue: activity.workoutConfiguration.activityType.rawValue,
                activityTypeName: OpenWearablesHealthSDK.shared._workoutTypeString(activity.workoutConfiguration.activityType),
                startDate: activity.startDate,
                endDate: activity.endDate,
                startElapsedOffset: WorkoutDetailMapping.elapsedOffset(of: activity.startDate, from: workout.startDate),
                endElapsedOffset: activity.endDate.map {
                    WorkoutDetailMapping.elapsedOffset(of: $0, from: workout.startDate)
                },
                duration: activity.duration,
                statistics: heartRateStatistics(for: activity),
                metadata: metadata
            )
        }

        return WorkoutActivitiesDetail(
            availability: WorkoutDetailMapping.availability(isReadable: true, count: activities.count),
            activities: activities,
            isSupportedOnThisOS: true
        )
    }

    /// Summary statistics HealthKit associates with an activity. Heart rate only for
    /// the first slice; the shape generalises to other metrics without change.
    @available(iOS 16.0, *)
    private func heartRateStatistics(for activity: HKWorkoutActivity) -> [ActivityStatistic] {
        guard let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate),
              let statistics = activity.statistics(for: heartRateType) else { return [] }

        let bpm = HKUnit.count().unitDivided(by: .minute())
        let identifier = heartRateType.identifier
        var result: [ActivityStatistic] = []
        if let minimum = statistics.minimumQuantity() {
            result.append(ActivityStatistic(quantityTypeIdentifier: identifier, aggregation: "minimum", value: minimum.doubleValue(for: bpm), unit: "count/min"))
        }
        if let average = statistics.averageQuantity() {
            result.append(ActivityStatistic(quantityTypeIdentifier: identifier, aggregation: "average", value: average.doubleValue(for: bpm), unit: "count/min"))
        }
        if let maximum = statistics.maximumQuantity() {
            result.append(ActivityStatistic(quantityTypeIdentifier: identifier, aggregation: "maximum", value: maximum.doubleValue(for: bpm), unit: "count/min"))
        }
        return result
    }

    // MARK: Query plumbing

    private func runSampleQuery(
        sampleType: HKSampleType,
        predicate: NSPredicate?,
        limit: Int,
        sortDescriptors: [NSSortDescriptor]?
    ) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sampleType,
                predicate: predicate,
                limit: limit,
                sortDescriptors: sortDescriptors
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: WorkoutDetailReaderError.queryFailed(error.localizedDescription))
                    return
                }
                continuation.resume(returning: samples ?? [])
            }
            healthStore.execute(query)
        }
    }
}
