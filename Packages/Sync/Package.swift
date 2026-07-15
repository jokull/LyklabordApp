// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sync",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(name: "Sync", targets: ["Sync"]),
    ],
    dependencies: [
        // For the PersonalModel schema types (`WordStats`, `TouchKeyStats`,
        // `EventLog.ConsumedMarker`) and the shared configuration defaults
        // (bigram cap, days-seen cap) — the merge must enforce the same
        // limits compaction does.
        .package(path: "../Learning"),
    ],
    targets: [
        .target(
            name: "Sync",
            dependencies: [
                .product(name: "Learning", package: "Learning"),
            ]
        ),
        .testTarget(
            name: "SyncTests",
            dependencies: ["Sync"]
        ),
    ],
    // Same rationale as Packages/Learning: tools 6.0 for `.iOS(.v18)`,
    // language mode pinned to v5 so this is not a strict-concurrency
    // migration.
    swiftLanguageModes: [.v5]
)
