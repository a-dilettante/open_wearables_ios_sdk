import Foundation

/// Verifies that a produced fixture retains nothing identifying from the workout it
/// was derived from.
///
/// This is the last line of defence before a fixture is committed or exported. It
/// works on the raw fixture bytes rather than on a parsed tree, so a value that
/// leaked into a key, a nested string, or an unexpected field is still caught.
///
/// The guard never puts a leaked value into its own output — a violation reports the
/// category, a non-sensitive location label, and a short hash prefix. An error message
/// containing the coordinate it just caught would defeat the purpose.
public enum RedactionGuard {

    /// What kind of identifying value was found.
    public enum Category: String, Sendable {
        case coordinate
        case absoluteTimestamp = "absolute_timestamp"
        case uuid
        case sourceIdentifier = "source_identifier"
        case deviceIdentifier = "device_identifier"
        case timeZoneIdentifier = "time_zone_identifier"
    }

    /// One surviving value. Deliberately carries no sample of the value itself.
    public struct Violation: Equatable, Sendable, CustomStringConvertible {
        public let category: Category
        /// Non-sensitive path label, e.g. "route.part[0].point[12].latitude".
        public let location: String
        /// First 8 hex of SHA-256 of the needle, so two runs can be correlated
        /// without the value ever being written down.
        public let needleHashPrefix: String

        public var description: String {
            "\(category.rawValue) survived at \(location) (needle \(needleHashPrefix))"
        }
    }

    /// Outcome of a scan.
    public struct Report: Sendable {
        public let violations: [Violation]
        /// How many distinct needles were actually searched for.
        public let checkedNeedleCount: Int
        /// Needles shorter than `minimumNeedleLength`, which are skipped because a
        /// 2-3 character value matches by coincidence and would make the guard useless.
        public let skippedShortNeedleCount: Int

        public var isClean: Bool { violations.isEmpty }

        /// Redaction-safe one-line summary, suitable for display in the diagnostic app.
        public var summary: String {
            if isClean {
                return "PASS — \(checkedNeedleCount) identifying values checked, none survived"
                    + (skippedShortNeedleCount > 0 ? " (\(skippedShortNeedleCount) too short to check)" : "")
            }
            let categories = Set(violations.map { $0.category.rawValue }).sorted().joined(separator: ", ")
            return "FAIL — \(violations.count) of \(checkedNeedleCount) identifying values survived (\(categories))"
        }
    }

    public enum GuardError: Error, CustomStringConvertible {
        case redactionFailed(Report)

        public var description: String {
            switch self {
            case .redactionFailed(let report): return report.summary
            }
        }
    }

    /// Values shorter than this are not searched for: a short string matches by
    /// coincidence and would produce noise instead of protection.
    public static let minimumNeedleLength = 6

    // MARK: - Public API

    /// Scans the fixture bytes for anything identifying from the original detail.
    public static func inspect(original: CollectedWorkoutDetail, fixtureData: Data) -> Report {
        let candidates = needles(for: original)
        var checked: [Needle] = []
        var skipped = 0
        var seen = Set<String>()

        for candidate in candidates {
            guard candidate.value.utf8.count >= minimumNeedleLength else {
                skipped += 1
                continue
            }
            // Dedupe by value so a repeated source key is scanned once.
            for value in Self.searchVariants(of: candidate.value) where seen.insert(value).inserted {
                checked.append(Needle(category: candidate.category, location: candidate.location, value: value))
            }
        }

        let found = scan(needles: checked, in: [UInt8](fixtureData))
        let violations = found.map {
            Violation(
                category: $0.category,
                location: $0.location,
                needleHashPrefix: String(WorkoutDetailHashing.sha256Hex($0.value).prefix(8))
            )
        }

        return Report(
            violations: violations,
            checkedNeedleCount: checked.count,
            skippedShortNeedleCount: skipped
        )
    }

    /// Throws unless the fixture is clean. Use before writing, committing, or sharing.
    public static func verify(original: CollectedWorkoutDetail, fixtureData: Data) throws {
        let report = inspect(original: original, fixtureData: fixtureData)
        guard report.isClean else { throw GuardError.redactionFailed(report) }
    }

    // MARK: - Needles

    struct Needle {
        let category: Category
        let location: String
        let value: String
    }

    /// Every identifying representation the original detail could leak.
    static func needles(for detail: CollectedWorkoutDetail) -> [Needle] {
        var result: [Needle] = []
        let identity = detail.identity

        // Identity strings.
        result.append(Needle(category: .uuid, location: "identity.workout_uuid", value: identity.workoutUUID))
        appendOptional(&result, .uuid, "identity.sync_identifier", identity.syncIdentifier)
        appendOptional(&result, .uuid, "identity.external_uuid", identity.externalUUID)
        result.append(Needle(category: .sourceIdentifier, location: "identity.source_bundle_id", value: identity.sourceBundleIdentifier))
        result.append(Needle(category: .sourceIdentifier, location: "identity.source_name", value: identity.sourceName))
        appendOptional(&result, .sourceIdentifier, "identity.source_version", identity.sourceVersion)
        appendOptional(&result, .deviceIdentifier, "identity.source_product_type", identity.sourceProductType)
        appendOptional(&result, .deviceIdentifier, "identity.device_name", identity.deviceName)
        appendOptional(&result, .deviceIdentifier, "identity.device_manufacturer", identity.deviceManufacturer)
        appendOptional(&result, .deviceIdentifier, "identity.device_model", identity.deviceModel)
        appendOptional(&result, .deviceIdentifier, "identity.device_hardware_version", identity.deviceHardwareVersion)
        appendOptional(&result, .deviceIdentifier, "identity.device_software_version", identity.deviceSoftwareVersion)
        // A zone identifier narrows down where the workout happened.
        appendOptional(&result, .timeZoneIdentifier, "identity.time_zone_identifier", identity.timeZoneIdentifier)

        // Absolute workout bounds.
        result.append(contentsOf: timestampNeedles(identity.startDate, location: "identity.start_date"))
        result.append(contentsOf: timestampNeedles(identity.endDate, location: "identity.end_date"))

        // Route: coordinates, route object UUIDs, point timestamps.
        for part in detail.route.parts {
            result.append(Needle(category: .uuid, location: "route.part[\(part.partIndex)].route_uuid", value: part.routeUUID))
            for point in part.points {
                let base = "route.part[\(part.partIndex)].point[\(point.ordinal)]"
                result.append(contentsOf: coordinateNeedles(point.latitude, location: "\(base).latitude"))
                result.append(contentsOf: coordinateNeedles(point.longitude, location: "\(base).longitude"))
                result.append(contentsOf: timestampNeedles(point.timestamp, location: "\(base).timestamp"))
            }
        }

        // Heart rate: sample UUIDs, source keys (they embed the real bundle id), dates.
        for entry in detail.heartRate.entries {
            let base = "heart_rate.entry[\(entry.ordinal)]"
            appendOptional(&result, .uuid, "\(base).sample_uuid", entry.sampleUUID)
            result.append(Needle(category: .sourceIdentifier, location: "\(base).source_key", value: entry.sourceKey))
            result.append(contentsOf: timestampNeedles(entry.startDate, location: "\(base).start_date"))
            result.append(contentsOf: timestampNeedles(entry.endDate, location: "\(base).end_date"))
        }

        // Events: dates and any free-text metadata value.
        for event in detail.events.events {
            let base = "events.event[\(event.ordinal)]"
            result.append(contentsOf: timestampNeedles(event.startDate, location: "\(base).start_date"))
            result.append(contentsOf: timestampNeedles(event.endDate, location: "\(base).end_date"))
            for (key, value) in event.metadata where Double(value) == nil {
                result.append(Needle(category: .sourceIdentifier, location: "\(base).metadata[\(key)]", value: value))
            }
        }

        // Activities: UUIDs, dates, free-text metadata.
        for activity in detail.activities.activities {
            let base = "activities.activity[\(activity.position)]"
            result.append(Needle(category: .uuid, location: "\(base).activity_uuid", value: activity.activityUUID))
            result.append(contentsOf: timestampNeedles(activity.startDate, location: "\(base).start_date"))
            if let endDate = activity.endDate {
                result.append(contentsOf: timestampNeedles(endDate, location: "\(base).end_date"))
            }
            for (key, value) in activity.metadata where Double(value) == nil {
                result.append(Needle(category: .sourceIdentifier, location: "\(base).metadata[\(key)]", value: value))
            }
        }

        return result
    }

    /// Every byte sequence a value can appear as inside a JSON document.
    ///
    /// `JSONSerialization` escapes `/` as `\/` unless `.withoutEscapingSlashes` is
    /// set, so a bundle identifier or time-zone name would slip past a literal search:
    /// `Europe/London` is written as `Europe\/London`. Quotes and backslashes escape
    /// the same way. Searching only the raw form would let escaping defeat the guard.
    static func searchVariants(of value: String) -> [String] {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "/", with: "\\/")
        return escaped == value ? [value] : [value, escaped]
    }

    private static func appendOptional(
        _ result: inout [Needle],
        _ category: Category,
        _ location: String,
        _ value: String?
    ) {
        guard let value, !value.isEmpty else { return }
        result.append(Needle(category: category, location: location, value: value))
    }

    /// Coordinate representations that would identify a place. Six decimals is the
    /// precision the acceptance gate requires be retained, and five catches a fixture
    /// that merely rounded instead of translating.
    static func coordinateNeedles(_ value: Double, location: String) -> [Needle] {
        guard value.isFinite, value != 0 else { return [] }
        return [6, 5].map { decimals in
            Needle(
                category: .coordinate,
                location: location,
                value: String(format: "%.\(decimals)f", value)
            )
        }
    }

    /// Absolute-time representations. The bare date is included because "which day the
    /// user exercised" is itself identifying, even without the time.
    static func timestampNeedles(_ date: Date, location: String) -> [Needle] {
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            "yyyy-MM-dd"
        ]
        var result: [Needle] = formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            return Needle(category: .absoluteTimestamp, location: location, value: formatter.string(from: date))
        }
        // Raw epoch seconds, in case a fixture ever emits a numeric timestamp.
        result.append(Needle(
            category: .absoluteTimestamp,
            location: location,
            value: String(Int(date.timeIntervalSince1970))
        ))
        return result
    }

    // MARK: - Scanner

    /// Finds which needles occur in `haystack`.
    ///
    /// Needles are bucketed by byte length and each bucket is swept with a rolling
    /// hash, so the cost is `O(haystack × distinctLengths)` instead of
    /// `O(haystack × needles)`. A long route produces tens of thousands of needles and
    /// the naive form would be unusably slow.
    static func scan(needles: [Needle], in haystack: [UInt8]) -> [Needle] {
        guard !haystack.isEmpty, !needles.isEmpty else { return [] }

        var byLength: [Int: [UInt64: [Needle]]] = [:]
        for needle in needles {
            let bytes = [UInt8](needle.value.utf8)
            guard !bytes.isEmpty, bytes.count <= haystack.count else { continue }
            byLength[bytes.count, default: [:]][hash(bytes), default: []].append(needle)
        }

        var found: [Needle] = []
        for (length, buckets) in byLength {
            var rolling = hash(Array(haystack[0..<length]))
            // Precompute base^(length-1) mod prime for the rolling subtraction.
            var highOrder: UInt64 = 1
            if length > 1 {
                for _ in 1..<length { highOrder = (highOrder &* base) % prime }
            }

            var start = 0
            while true {
                if let candidates = buckets[rolling] {
                    for candidate in candidates where matches(candidate.value, in: haystack, at: start) {
                        found.append(candidate)
                    }
                }
                guard start + length < haystack.count else { break }
                // Roll: drop the leading byte, shift, add the trailing byte.
                let leaving = (UInt64(haystack[start]) &* highOrder) % prime
                rolling = (rolling + prime - leaving) % prime
                rolling = (rolling &* base + UInt64(haystack[start + length])) % prime
                start += 1
            }
        }

        // Stable, readable ordering for the report.
        return found.sorted { lhs, rhs in
            if lhs.category.rawValue != rhs.category.rawValue { return lhs.category.rawValue < rhs.category.rawValue }
            return lhs.location < rhs.location
        }
    }

    private static let base: UInt64 = 257
    private static let prime: UInt64 = 1_000_000_007

    private static func hash(_ bytes: [UInt8]) -> UInt64 {
        var value: UInt64 = 0
        for byte in bytes { value = (value &* base + UInt64(byte)) % prime }
        return value
    }

    /// Exact byte comparison, because a rolling-hash hit can be a collision.
    private static func matches(_ needle: String, in haystack: [UInt8], at start: Int) -> Bool {
        let bytes = [UInt8](needle.utf8)
        guard start + bytes.count <= haystack.count else { return false }
        for offset in 0..<bytes.count where haystack[start + offset] != bytes[offset] {
            return false
        }
        return true
    }
}
