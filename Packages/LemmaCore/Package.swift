// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LemmaCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "LemmaCore", targets: ["LemmaCore"]),
        .executable(name: "lemma-bench", targets: ["lemma-bench"]),
    ],
    targets: [
        .target(
            name: "LemmaCore"
        ),
        .executableTarget(
            name: "lemma-bench",
            dependencies: ["LemmaCore"]
        ),
        .testTarget(
            name: "LemmaCoreTests",
            dependencies: ["LemmaCore"],
            resources: [
                .copy("Resources/lemma-is.core.bin"),
                .copy("Resources/lemmatize-fixture.json"),
            ]
        ),
    ]
)
