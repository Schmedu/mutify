// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mutify",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure decision logic. No I/O, no frameworks — fully unit-testable.
        .target(
            name: "MutifyCore",
            path: "Sources/MutifyCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The app: menu bar UI plus the CoreAudio / CoreWLAN / CoreLocation plumbing.
        .executableTarget(
            name: "Mutify",
            dependencies: ["MutifyCore"],
            path: "Sources/Mutify",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MutifyCoreTests",
            dependencies: ["MutifyCore"],
            path: "Tests/MutifyCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
