// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenWearablesHealthSDK",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "OpenWearablesHealthSDK", targets: ["OpenWearablesHealthSDK"]),
    ],
    targets: [
        .target(
            name: "OpenWearablesHealthSDK",
            path: "Sources/OpenWearablesHealthSDK",
            linkerSettings: [
                .linkedFramework("HealthKit"),
                .linkedFramework("BackgroundTasks"),
                // Workout routes are delivered as CLLocation values.
                .linkedFramework("CoreLocation"),
            ]
        ),
        .testTarget(
            name: "OpenWearablesHealthSDKTests",
            dependencies: ["OpenWearablesHealthSDK"],
            // Committed wire bytes for the cross-repo conformance fixture. Declared so the
            // build treats them as data rather than as unhandled files; the generating test
            // reads and rewrites them in the source tree, not in the bundle.
            resources: [.copy("GoldenFixtures")]
        ),
    ]
)
