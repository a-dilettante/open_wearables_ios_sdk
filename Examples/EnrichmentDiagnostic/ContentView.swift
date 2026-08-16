import SwiftUI
import OpenWearablesHealthSDK

/// Phase 0 diagnostic UI.
///
/// Everything this view renders comes from `WorkoutDetailProbe.Report`, which is built
/// only from counts, native type names, elapsed-offset durations, presence booleans, and
/// hash prefixes. The collected detail itself is held in memory to generate a fixture and
/// is never displayed.
///
/// There is no `print` or `NSLog` anywhere in this file. Health data must not reach a log.
struct ContentView: View {

    @StateObject private var model = DiagnosticModel()

    var body: some View {
        NavigationStack {
            List {
                authorizationSection
                if model.isAuthorized {
                    workoutsSection
                }
                if let report = model.report {
                    reportSection(report)
                    fixtureSection
                }
            }
            .navigationTitle("Enrichment Diagnostic")
            .refreshable { await model.loadWorkouts() }
        }
        .task { await model.start() }
    }

    // MARK: Authorization

    private var authorizationSection: some View {
        Section("HealthKit") {
            Text(model.authorizationStatus)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if !model.isAuthorized {
                Button("Request workout, route, and heart rate access") {
                    Task { await model.start() }
                }
            }
            // Apple never reveals whether a read type was denied, so a completed sheet
            // is not a promise that data will arrive.
            Text("A completed prompt does not guarantee access. Apple makes a denied read indistinguishable from missing data.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Workout picker

    private var workoutsSection: some View {
        Section("Recent workouts") {
            if model.workouts.isEmpty {
                Text(model.workoutsStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.workouts) { workout in
                Button {
                    Task { await model.runProbe(on: workout) }
                } label: {
                    HStack {
                        // Label carries no identifier and no absolute timestamp.
                        Text(workout.label)
                        Spacer()
                        if model.probingWorkoutID == workout.id {
                            ProgressView()
                        } else if model.probedWorkoutID == workout.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(model.probingWorkoutID != nil)
            }
        }
    }

    // MARK: Report

    private func reportSection(_ report: WorkoutDetailProbe.Report) -> some View {
        Section("Report (safe to screenshot)") {
            Text(report.text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    // MARK: Fixture export

    private var fixtureSection: some View {
        Section("Redacted fixture") {
            Button("Generate fixture") {
                model.generateFixture()
            }
            .disabled(model.isGeneratingFixture)

            if let guardSummary = model.guardSummary {
                Text(guardSummary)
                    .font(.footnote)
                    .foregroundStyle(model.fixtureURL == nil ? .red : .green)
            }

            // The share option only exists once the guard has confirmed the bytes are
            // clean. A failing guard means the fixture writer has a bug.
            if let url = model.fixtureURL {
                ShareLink(item: url) {
                    Label("Export fixture", systemImage: "square.and.arrow.up")
                }
            }

            ForEach(model.guardViolations, id: \.self) { violation in
                // Violations name a category and a location, never the value found.
                Text(violation)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Model

@MainActor
final class DiagnosticModel: ObservableObject {

    @Published var authorizationStatus = "Not requested yet."
    @Published var isAuthorized = false
    @Published var workouts: [WorkoutDetailProbe.WorkoutSummary] = []
    @Published var workoutsStatus = "No workouts found."
    @Published var probingWorkoutID: UUID?
    @Published var probedWorkoutID: UUID?
    @Published var report: WorkoutDetailProbe.Report?
    @Published var guardSummary: String?
    @Published var guardViolations: [String] = []
    @Published var fixtureURL: URL?
    @Published var isGeneratingFixture = false

    private let probe = WorkoutDetailProbe()
    private var collectedDetail: CollectedWorkoutDetail?

    /// Per-install redaction key. Stable so regenerating a fixture from the same workout
    /// produces identical bytes; random so two installs cannot be correlated.
    private static let redactionKeyDefaultsKey = "com.openwearables.diagnostic.redactionKey"

    private var redactionKey: String {
        if let existing = UserDefaults.standard.string(forKey: Self.redactionKeyDefaultsKey) {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: Self.redactionKeyDefaultsKey)
        return generated
    }

    func start() async {
        let completed = await probe.requestProbeAuthorization()
        isAuthorized = completed
        authorizationStatus = completed
            ? "Requested workout, workout route, and heart rate."
            : "HealthKit is unavailable, or the prompt could not be shown."
        if completed {
            await loadWorkouts()
        }
    }

    func loadWorkouts() async {
        do {
            workouts = try await probe.recentWorkoutSummaries(limit: 25)
            workoutsStatus = workouts.isEmpty
                ? "No workouts returned. Either none exist, or read access was not granted — Apple makes those indistinguishable."
                : ""
        } catch {
            workouts = []
            // The message describes the query, never the data.
            workoutsStatus = "Could not read workouts. If the device is locked, unlock it and pull to refresh."
        }
    }

    func runProbe(on workout: WorkoutDetailProbe.WorkoutSummary) async {
        probingWorkoutID = workout.id
        resetFixtureState()
        defer { probingWorkoutID = nil }

        do {
            let result = try await probe.probe(workoutID: workout.id)
            collectedDetail = result.detail
            report = result.report
            probedWorkoutID = workout.id
        } catch {
            report = nil
            collectedDetail = nil
            guardSummary = "Probe failed. If the device is locked, unlock it and try again."
        }
    }

    func generateFixture() {
        guard let detail = collectedDetail else { return }
        isGeneratingFixture = true
        resetFixtureState()
        defer { isGeneratingFixture = false }

        do {
            let data = try WorkoutDetailFixtureWriter.makeFixtureData(from: detail, key: redactionKey)

            // Gate the export on the guard: if anything identifying survived, there is
            // no share button at all.
            let inspection = RedactionGuard.inspect(original: detail, fixtureData: data)
            guardSummary = inspection.summary
            guard inspection.isClean else {
                guardViolations = inspection.violations.map { $0.description }
                return
            }

            fixtureURL = try write(data, rootHashPrefix: report?.rootHashPrefix ?? "fixture")
        } catch {
            guardSummary = "Could not generate the fixture."
        }
    }

    private func resetFixtureState() {
        guardSummary = nil
        guardViolations = []
        fixtureURL = nil
    }

    /// Writes to the temporary directory, excluded from iCloud and device backups.
    private func write(_ data: Data, rootHashPrefix: String) throws -> URL {
        var url = FileManager.default.temporaryDirectory
            .appendingPathComponent("workout-detail-fixture-\(rootHashPrefix).json")
        try data.write(to: url, options: [.atomic, .completeFileProtection])

        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try url.setResourceValues(resourceValues)
        return url
    }
}
