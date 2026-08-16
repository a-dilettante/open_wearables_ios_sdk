import SwiftUI

/// Entry point for the Phase 0 enrichment diagnostic.
///
/// Not part of the Swift package — see `README.md` for how to create the app target
/// this belongs to. Requires a physical device with the HealthKit capability and an
/// `NSHealthShareUsageDescription` string.
@main
struct DiagnosticApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
