// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SweetMX",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "SweetMX", targets: ["SweetMX"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.19.6"),
    ],
    targets: [
        .executableTarget(
            name: "SweetMX",
            path: "Sources/SweetMX",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
            ]
        ),
        .testTarget(
            name: "SweetMXTests",
            dependencies: [
                "SweetMX",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            path: "Tests/SweetMXTests",
            exclude: ["__Snapshots__"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // XCTestCase initializers are nonisolated, so default main-actor isolation cannot
                // apply here; test classes opt in with an explicit @MainActor instead.
            ]
        ),
        // The performance gate. Its own target so `swift test` (debug) keeps the functional suite
        // fast, and `make benchmark` can build this one with optimizations, as the shipped app is.
        .testTarget(
            name: "SweetMXBenchmarks",
            dependencies: ["SweetMX"],
            path: "Tests/SweetMXBenchmarks",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
