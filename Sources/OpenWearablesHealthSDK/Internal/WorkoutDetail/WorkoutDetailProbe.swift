import Foundation
import HealthKit

/// Phase 0 device probe: reads one workout's owned detail and reports what HealthKit
/// actually exposed, without ever surfacing the data itself.
///
/// Everything this type returns is safe to screenshot, paste into a ticket, or read
/// aloud. That is enforced structurally rather than by filtering: the report is built
/// only from counts, native type names, elapsed-offset durations, presence booleans,
/// and short hash prefixes. No code path can put a coordinate, a sample value, an
/// absolute timestamp, a HealthKit UUID, a bundle identifier, or a device name into it,
/// because none of those values are ever passed to the report builder.
///
/// Nothing here logs health data. The SDK's `logMessage` is not used at all.
public final class WorkoutDetailProbe: @unchecked Sendable {

    private let healthStore: HKHealthStore
    private let reader: WorkoutDetailReader

    public init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
        self.reader = WorkoutDetailReader(healthStore: healthStore)
    }

    // MARK: - Authorization

    /// Exactly the three read types the first slice needs.
    ///
    /// Workout authorization alone does not grant route or quantity access, so all
    /// three are requested together.
    public static func probeReadTypes() -> Set<HKObjectType> {
        var types: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute()
        ]
        if let heartRate = HKObjectType.quantityType(forIdentifier: .heartRate) {
            types.insert(heartRate)
        }
        return types
    }

    /// Requests read access for the probe's three types only.
    ///
    /// This deliberately does **not** call
    /// `OpenWearablesHealthSDK.requestAuthorization(types:completion:)`. That method
    /// replaces the SDK's persisted `trackedTypes` set, so routing the probe through it
    /// would silently reduce a host app's tracked types to these three and break its
    /// core sync. The probe therefore talks to `HKHealthStore` directly and leaves all
    /// SDK state untouched.
    ///
    /// The returned flag only means the sheet completed. Apple never reveals whether a
    /// read type was actually granted, so `true` is not a promise that data will arrive.
    @discardableResult
    public func requestProbeAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        return await withCheckedContinuation { continuation in
            healthStore.requestAuthorization(toShare: nil, read: Self.probeReadTypes()) { completed, _ in
                continuation.resume(returning: completed)
            }
        }
    }

    // MARK: - Workout selection

    /// A workout the user can pick, labelled without exposing its identity.
    public struct WorkoutSummary: Identifiable, Sendable {
        /// Kept in memory only so the probe can re-fetch the workout. Never rendered
        /// and never placed in a report.
        public let id: UUID
        public let activityTypeName: String
        public let durationSeconds: TimeInterval
        public let daysAgo: Int

        /// e.g. "running — 42:13 — 3 days ago". Carries no identifier and no absolute
        /// timestamp; "days ago" is a coarse relative bucket for picking from a list.
        public var label: String {
            "\(activityTypeName) — \(WorkoutDetailProbe.durationLabel(durationSeconds)) — \(WorkoutDetailProbe.relativeLabel(daysAgo))"
        }
    }

    /// Most-recent-first workouts for the picker.
    public func recentWorkoutSummaries(limit: Int = 25) async throws -> [WorkoutSummary] {
        let workouts = try await reader.recentWorkouts(limit: limit)
        let now = Date()
        return workouts.map { workout in
            WorkoutSummary(
                id: workout.uuid,
                activityTypeName: OpenWearablesHealthSDK.shared._workoutTypeString(workout.workoutActivityType),
                durationSeconds: workout.duration,
                daysAgo: max(0, Int(now.timeIntervalSince(workout.startDate) / 86_400))
            )
        }
    }

    // MARK: - Probe

    /// Collected detail plus its report. The detail is returned so the caller can
    /// generate a fixture; only the report is safe to display.
    public struct ProbeResult {
        public let detail: CollectedWorkoutDetail
        public let report: Report
    }

    public func probe(workoutID: UUID) async throws -> ProbeResult {
        let workout = try await reader.fetchWorkout(uuid: workoutID)
        let detail = await reader.collectDetail(for: workout)
        return ProbeResult(detail: detail, report: Self.makeReport(for: detail))
    }

    // MARK: - Report

    /// What one family exposed. Counts, types, and durations only.
    public struct FamilyReport: Sendable {
        public let family: WorkoutDetailFamily
        public let availability: WorkoutDetailAvailability
        public let count: Int
        /// Native types actually observed, e.g. `["lap", "segment", "pause"]`.
        public let nativeTypesSeen: [String]
        /// Bounds expressed as offsets from the workout start, in seconds.
        public let firstElapsedOffset: TimeInterval?
        public let lastElapsedOffset: TimeInterval?
        /// Structural observations such as `route_parts=2` or `batches=7`.
        public let notes: [String]
        public let hashPrefix: String
    }

    /// A redaction-safe description of one probed workout.
    public struct Report: Sendable {
        public let schemaVersion: Int
        public let canonicalizationVersion: Int
        /// e.g. "running". A sport name is not identifying.
        public let activityTypeName: String
        public let activityTypeRawValue: UInt
        /// `HKWorkout.duration` — excludes paused time.
        public let durationSeconds: TimeInterval
        /// `endDate - startDate`. Differs from `durationSeconds` when the workout paused.
        public let spanSeconds: TimeInterval
        /// Presence flags only. The values themselves are identifying and are not read.
        public let hasSyncIdentifier: Bool
        public let hasSyncVersion: Bool
        public let hasExternalUUID: Bool
        public let hasDeviceInformation: Bool
        public let hasTimeZoneOffset: Bool
        public let families: [FamilyReport]
        public let rootHashPrefix: String

        public func family(_ family: WorkoutDetailFamily) -> FamilyReport? {
            families.first { $0.family == family }
        }

        /// Multi-line rendering for the diagnostic UI. Safe to screenshot.
        public var text: String {
            var lines: [String] = [
                "workout: \(activityTypeName) (raw \(activityTypeRawValue))",
                "duration: \(WorkoutDetailProbe.durationLabel(durationSeconds))"
                    + "  span: \(WorkoutDetailProbe.durationLabel(spanSeconds))",
                "identity present: sync_id=\(yesNo(hasSyncIdentifier))"
                    + " sync_version=\(yesNo(hasSyncVersion))"
                    + " external_uuid=\(yesNo(hasExternalUUID))"
                    + " device=\(yesNo(hasDeviceInformation))"
                    + " tz_offset=\(yesNo(hasTimeZoneOffset))",
                "schema v\(schemaVersion) / canon v\(canonicalizationVersion) / root \(rootHashPrefix)",
                ""
            ]
            for report in families {
                lines.append("[\(report.family.rawValue)] \(report.availability.rawValue) — \(report.count) entries — \(report.hashPrefix)")
                if !report.nativeTypesSeen.isEmpty {
                    lines.append("  native types: \(report.nativeTypesSeen.joined(separator: ", "))")
                }
                if let first = report.firstElapsedOffset, let last = report.lastElapsedOffset {
                    lines.append("  offsets: +\(WorkoutDetailProbe.durationLabel(first)) … +\(WorkoutDetailProbe.durationLabel(last))")
                }
                if !report.notes.isEmpty {
                    lines.append("  \(report.notes.joined(separator: "  "))")
                }
            }
            return lines.joined(separator: "\n")
        }

        private func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }
    }

    /// Builds the report. Every argument passed onward is a count, a type name, a
    /// duration, a boolean, or a hash prefix — never a value read from the workout.
    public static func makeReport(for detail: CollectedWorkoutDetail) -> Report {
        let hashes = WorkoutDetailHashing.hashes(for: detail)

        // Route
        let points = WorkoutDetailHashing.sortedPoints(detail.route.parts.flatMap { $0.points })
        var routeNotes = ["route_parts=\(detail.route.parts.count)"]
        routeNotes.append("batches=\(detail.route.parts.reduce(0) { $0 + $1.batchCount })")
        routeNotes.append("with_altitude=\(points.filter { $0.altitude != nil }.count)")
        routeNotes.append("with_horizontal_accuracy=\(points.filter { $0.horizontalAccuracy != nil }.count)")
        routeNotes.append("with_speed=\(points.filter { $0.speed != nil }.count)")
        routeNotes.append("with_course=\(points.filter { $0.course != nil }.count)")
        let routeReport = FamilyReport(
            family: .route,
            availability: detail.route.availability,
            count: points.count,
            nativeTypesSeen: detail.route.parts.isEmpty ? [] : ["HKWorkoutRoute"],
            firstElapsedOffset: points.first?.elapsedOffset,
            lastElapsedOffset: points.last?.elapsedOffset,
            notes: routeNotes,
            hashPrefix: hashes.prefix(for: .route)
        )

        // Heart rate
        let entries = WorkoutDetailHashing.sortedEntries(detail.heartRate.entries)
        let intervalCount = entries.filter { $0.kind == .interval }.count
        let expandedCount = entries.filter { $0.isExpandedFromSeries }.count
        let heartRateReport = FamilyReport(
            family: .heartRate,
            availability: detail.heartRate.availability,
            count: entries.count,
            nativeTypesSeen: entries.isEmpty ? [] : Array(Set(entries.map { $0.kind.rawValue })).sorted(),
            firstElapsedOffset: entries.first?.startElapsedOffset,
            lastElapsedOffset: entries.last?.endElapsedOffset,
            notes: [
                "top_level_samples=\(detail.heartRate.topLevelSampleCount)",
                "expanded_from_series=\(expandedCount)",
                "intervals=\(intervalCount)",
                "points=\(entries.count - intervalCount)",
                // How many independent recording sources contributed, without naming them.
                "distinct_sources=\(Set(entries.map { $0.sourceKey }).count)",
                "unit=\(entries.first?.unit ?? "-")"
            ],
            hashPrefix: hashes.prefix(for: .heartRate)
        )

        // Events
        let events = WorkoutDetailHashing.sortedEvents(detail.events.events)
        let eventsReport = FamilyReport(
            family: .events,
            availability: detail.events.availability,
            count: events.count,
            nativeTypesSeen: Array(Set(events.map { $0.typeName })).sorted(),
            firstElapsedOffset: events.first?.startElapsedOffset,
            lastElapsedOffset: events.last?.endElapsedOffset,
            notes: [
                "zero_duration=\(events.filter { $0.isZeroDuration }.count)",
                "with_metadata=\(events.filter { !$0.metadata.isEmpty }.count)"
            ],
            hashPrefix: hashes.prefix(for: .events)
        )

        // Activities
        let activities = WorkoutDetailHashing.sortedActivities(detail.activities.activities)
        var activityNotes = ["os_supported=\(detail.activities.isSupportedOnThisOS ? "yes" : "no")"]
        activityNotes.append("with_statistics=\(activities.filter { !$0.statistics.isEmpty }.count)")
        activityNotes.append("open_ended=\(activities.filter { $0.endDate == nil }.count)")
        let activitiesReport = FamilyReport(
            family: .activities,
            availability: detail.activities.availability,
            count: activities.count,
            nativeTypesSeen: Array(Set(activities.map { $0.activityTypeName })).sorted(),
            firstElapsedOffset: activities.first?.startElapsedOffset,
            lastElapsedOffset: activities.compactMap { $0.endElapsedOffset }.max(),
            notes: activityNotes,
            hashPrefix: hashes.prefix(for: .activities)
        )

        return Report(
            schemaVersion: CollectedWorkoutDetail.schemaVersion,
            canonicalizationVersion: WorkoutDetailHashing.canonicalizationVersion,
            activityTypeName: detail.identity.activityTypeName,
            activityTypeRawValue: detail.identity.activityTypeRawValue,
            durationSeconds: detail.identity.duration,
            spanSeconds: detail.identity.endDate.timeIntervalSince(detail.identity.startDate),
            hasSyncIdentifier: detail.identity.syncIdentifier != nil,
            hasSyncVersion: detail.identity.syncVersion != nil,
            hasExternalUUID: detail.identity.externalUUID != nil,
            hasDeviceInformation: detail.identity.deviceModel != nil
                || detail.identity.deviceManufacturer != nil
                || detail.identity.deviceName != nil,
            hasTimeZoneOffset: detail.identity.timeZoneOffsetSeconds != nil,
            families: [routeReport, heartRateReport, eventsReport, activitiesReport],
            rootHashPrefix: hashes.rootPrefix
        )
    }

    // MARK: - Labels

    /// "42:13", or "1:02:44" past an hour. A duration is not identifying.
    static func durationLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let sign = total < 0 ? "-" : ""
        let absolute = abs(total)
        let hours = absolute / 3600
        let minutes = (absolute % 3600) / 60
        let remainder = absolute % 60
        if hours > 0 {
            return String(format: "%@%d:%02d:%02d", sign, hours, minutes, remainder)
        }
        return String(format: "%@%d:%02d", sign, minutes, remainder)
    }

    /// Coarse relative bucket. Deliberately not a date.
    static func relativeLabel(_ daysAgo: Int) -> String {
        switch daysAgo {
        case 0: return "today"
        case 1: return "yesterday"
        default: return "\(daysAgo) days ago"
        }
    }
}
