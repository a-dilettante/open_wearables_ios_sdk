import Foundation
@testable import OpenWearablesHealthSDK

/// Synthetic workout detail used by the workout-detail tests.
///
/// Every value here is invented, but it is deliberately shaped like real HealthKit
/// output: uppercase UUID strings, a reverse-DNS bundle identifier, a human device
/// name, a real-looking city coordinate, and a specific absolute date. That is the
/// point — these are the values the redaction guard must prove cannot survive into a
/// fixture.
///
/// None of this touches HealthKit, so the suite runs without entitlements.
enum WorkoutDetailTestFixtures {

    // MARK: - Identifying constants (redaction bait)

    static let workoutUUID = "A1B2C3D4-0000-4000-8000-000000000001"
    static let routeUUID = "A1B2C3D4-0000-4000-8000-000000000002"
    static let secondRouteUUID = "A1B2C3D4-0000-4000-8000-000000000003"
    static let sampleUUID = "A1B2C3D4-0000-4000-8000-000000000004"
    static let activityUUID = "A1B2C3D4-0000-4000-8000-000000000005"
    static let syncIdentifier = "acme-sync-9f3c1d77"
    static let externalUUID = "acme-external-4b2a8e10"

    static let sourceBundleIdentifier = "com.acme.runtracker"
    static let sourceName = "Acme Run Tracker"
    static let sourceVersion = "7.4.1"
    static let productType = "Watch6,18"
    static let deviceName = "Alexs Apple Watch"
    static let deviceManufacturer = "Apple Inc."
    static let deviceModel = "Watch Ultra 2"
    static let timeZoneIdentifier = "Europe/London"

    /// A specific real-looking start location and the absolute moment it happened.
    static let originLatitude = 51.507351
    static let originLongitude = -0.127758

    /// 2026-08-15T07:15:00Z.
    static let workoutStart = Date(timeIntervalSince1970: 1_786_778_100)

    /// The real absolute start as it would be rendered into JSON. Tests inject this to
    /// prove the guard catches a writer that forgot to rebase; deriving it (rather than
    /// hard-coding a literal) keeps the assertion honest if the constant ever moves.
    static var workoutStartISO: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: workoutStart)
    }

    /// Just the calendar day of the real workout — "which day the user exercised" is
    /// itself identifying and must not survive.
    static var workoutStartDay: String { String(workoutStartISO.prefix(10)) }

    static let sourceKey = "\(sourceBundleIdentifier)|\(productType)|\(deviceModel)"

    // MARK: - Builders

    static func identity() -> WorkoutIdentity {
        WorkoutIdentity(
            workoutUUID: workoutUUID,
            syncIdentifier: syncIdentifier,
            syncVersion: 3,
            externalUUID: externalUUID,
            sourceBundleIdentifier: sourceBundleIdentifier,
            sourceName: sourceName,
            sourceVersion: sourceVersion,
            sourceProductType: productType,
            sourceOperatingSystemVersion: "10.4.0",
            deviceName: deviceName,
            deviceManufacturer: deviceManufacturer,
            deviceModel: deviceModel,
            deviceHardwareVersion: "Watch6,18",
            deviceSoftwareVersion: "10.4",
            timeZoneIdentifier: timeZoneIdentifier,
            timeZoneOffsetSeconds: 3600,
            activityTypeRawValue: 37,
            activityTypeName: "running",
            startDate: workoutStart,
            // 45 minutes wall-clock, 43 minutes moving (a 2-minute pause).
            endDate: workoutStart.addingTimeInterval(2700),
            duration: 2580
        )
    }

    /// Route with two parts and a deliberate gap between them, so gap structure has
    /// something to preserve.
    ///
    /// Offsets are irregular on purpose: HealthKit publishes no cadence guarantee and
    /// nothing downstream may assume 1 Hz or uniform spacing.
    static func route() -> WorkoutRouteDetail {
        // Irregular spacing, and a 300s gap between part 0 and part 1.
        let firstOffsets: [TimeInterval] = [0, 1, 2.5, 4, 7, 11.25, 18, 30]
        let secondOffsets: [TimeInterval] = [330, 331.5, 334, 340]

        func makePoints(_ offsets: [TimeInterval], startIndex: Int) -> [RoutePoint] {
            offsets.enumerated().map { index, offset in
                // Walk roughly north-east, ~1e-4 degrees per step (about 11 m).
                let step = Double(startIndex + index)
                return RoutePoint(
                    timestamp: workoutStart.addingTimeInterval(offset),
                    elapsedOffset: offset,
                    latitude: originLatitude + step * 0.000_1,
                    longitude: originLongitude + step * 0.000_15,
                    altitude: 12.5 + step * 0.4,
                    speed: 3.1 + Double(index % 3) * 0.2,
                    course: 87.4,
                    horizontalAccuracy: 4.0,
                    // Some points legitimately have no vertical accuracy.
                    verticalAccuracy: index % 2 == 0 ? 3.0 : nil,
                    ordinal: index
                )
            }
        }

        return WorkoutRouteDetail(
            availability: .available,
            parts: [
                RoutePart(routeUUID: routeUUID, partIndex: 0, batchCount: 2, points: makePoints(firstOffsets, startIndex: 0)),
                RoutePart(routeUUID: secondRouteUUID, partIndex: 1, batchCount: 1, points: makePoints(secondOffsets, startIndex: 8))
            ]
        )
    }

    /// Heart rate mixing plain point samples with entries expanded from a condensed
    /// series, including a coalesced interval and two entries sharing a timestamp.
    static func heartRate() -> WorkoutQuantityStream {
        var entries: [QuantityEntry] = []

        // Two point samples.
        for index in 0..<2 {
            let offset = TimeInterval(index) * 5
            entries.append(QuantityEntry(
                startDate: workoutStart.addingTimeInterval(offset),
                endDate: workoutStart.addingTimeInterval(offset),
                startElapsedOffset: offset,
                endElapsedOffset: offset,
                value: 128 + Double(index),
                unit: "count/min",
                sampleUUID: sampleUUID,
                sourceKey: sourceKey,
                kind: .point,
                isExpandedFromSeries: false,
                parentSeriesCount: 1,
                ordinal: index
            ))
        }

        // A coalesced interval: one value covering 10..25s. Its span must survive.
        entries.append(QuantityEntry(
            startDate: workoutStart.addingTimeInterval(10),
            endDate: workoutStart.addingTimeInterval(25),
            startElapsedOffset: 10,
            endElapsedOffset: 25,
            value: 142,
            unit: "count/min",
            sampleUUID: sampleUUID,
            sourceKey: sourceKey,
            kind: .interval,
            isExpandedFromSeries: true,
            parentSeriesCount: 12,
            ordinal: 2
        ))

        // Two entries at the same offset from different sources — legal, and must not
        // be deduplicated or reordered non-deterministically.
        for index in 0..<2 {
            entries.append(QuantityEntry(
                startDate: workoutStart.addingTimeInterval(40),
                endDate: workoutStart.addingTimeInterval(40),
                startElapsedOffset: 40,
                endElapsedOffset: 40,
                value: 150 + Double(index),
                unit: "count/min",
                sampleUUID: sampleUUID,
                sourceKey: index == 0 ? sourceKey : "com.acme.strap|-|HRM-Pro",
                kind: .point,
                isExpandedFromSeries: false,
                parentSeriesCount: 1,
                ordinal: 3 + index
            ))
        }

        return WorkoutQuantityStream(
            availability: .available,
            metric: "heart_rate",
            quantityTypeIdentifier: "HKQuantityTypeIdentifierHeartRate",
            entries: entries,
            topLevelSampleCount: 4
        )
    }

    /// Events covering a zero-duration legacy lap, an overlapping segment pair, and a
    /// pause/resume couple.
    static func events() -> WorkoutEventsDetail {
        WorkoutEventsDetail(availability: .available, events: [
            // Legacy zero-duration lap marker.
            WorkoutEventEntry(
                typeRawValue: 3, typeName: "lap",
                startDate: workoutStart.addingTimeInterval(600),
                endDate: workoutStart.addingTimeInterval(600),
                startElapsedOffset: 600, endElapsedOffset: 600,
                metadata: [:], ordinal: 0
            ),
            // Segments are allowed to overlap each other.
            WorkoutEventEntry(
                typeRawValue: 7, typeName: "segment",
                startDate: workoutStart.addingTimeInterval(0),
                endDate: workoutStart.addingTimeInterval(900),
                startElapsedOffset: 0, endElapsedOffset: 900,
                metadata: ["HKMetadataKeySegmentLabel": "warmup", "acmeNote": "Alexs tempo block"],
                ordinal: 1
            ),
            WorkoutEventEntry(
                typeRawValue: 7, typeName: "segment",
                startDate: workoutStart.addingTimeInterval(600),
                endDate: workoutStart.addingTimeInterval(1500),
                startElapsedOffset: 600, endElapsedOffset: 1500,
                metadata: [:], ordinal: 2
            ),
            WorkoutEventEntry(
                typeRawValue: 1, typeName: "pause",
                startDate: workoutStart.addingTimeInterval(1500),
                endDate: workoutStart.addingTimeInterval(1500),
                startElapsedOffset: 1500, endElapsedOffset: 1500,
                metadata: [:], ordinal: 3
            ),
            WorkoutEventEntry(
                typeRawValue: 2, typeName: "resume",
                startDate: workoutStart.addingTimeInterval(1620),
                endDate: workoutStart.addingTimeInterval(1620),
                startElapsedOffset: 1620, endElapsedOffset: 1620,
                metadata: [:], ordinal: 4
            )
        ])
    }

    static func activities() -> WorkoutActivitiesDetail {
        WorkoutActivitiesDetail(
            availability: .available,
            activities: [
                WorkoutActivityEntry(
                    activityUUID: activityUUID,
                    position: 0,
                    activityTypeRawValue: 37,
                    activityTypeName: "running",
                    startDate: workoutStart,
                    endDate: workoutStart.addingTimeInterval(2700),
                    startElapsedOffset: 0,
                    endElapsedOffset: 2700,
                    duration: 2580,
                    statistics: [
                        ActivityStatistic(quantityTypeIdentifier: "HKQuantityTypeIdentifierHeartRate", aggregation: "average", value: 148.2, unit: "count/min"),
                        ActivityStatistic(quantityTypeIdentifier: "HKQuantityTypeIdentifierHeartRate", aggregation: "maximum", value: 176, unit: "count/min")
                    ],
                    metadata: ["HKMetadataKeyIndoorWorkout": "0"]
                )
            ],
            isSupportedOnThisOS: true
        )
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

    /// The same detail with every collection reversed. Canonical sorting must make it
    /// hash identically to `detail()`.
    static func permutedDetail() -> CollectedWorkoutDetail {
        var permuted = detail()
        permuted.route.parts.reverse()
        for index in permuted.route.parts.indices {
            permuted.route.parts[index].points.reverse()
        }
        permuted.heartRate.entries.reverse()
        permuted.events.events.reverse()
        permuted.activities.activities.reverse()
        return permuted
    }

    /// Every route point across all parts, in canonical order.
    static func allRoutePoints(_ detail: CollectedWorkoutDetail) -> [RoutePoint] {
        WorkoutDetailHashing.sortedParts(detail.route.parts).flatMap {
            WorkoutDetailHashing.sortedPoints($0.points)
        }
    }

    /// Great-circle distance in metres, for asserting the rotation preserved geometry.
    static func haversineMetres(
        _ first: (latitude: Double, longitude: Double),
        _ second: (latitude: Double, longitude: Double)
    ) -> Double {
        let radius = 6_378_137.0
        let toRadians = Double.pi / 180
        let lat1 = first.latitude * toRadians
        let lat2 = second.latitude * toRadians
        let deltaLat = (second.latitude - first.latitude) * toRadians
        let deltaLon = (second.longitude - first.longitude) * toRadians
        let a = sin(deltaLat / 2) * sin(deltaLat / 2)
            + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        return 2 * radius * atan2(sqrt(a), sqrt(1 - a))
    }
}
