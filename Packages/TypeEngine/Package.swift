// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TypeEngine",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(name: "TypeEngine", targets: ["TypeEngine"]),
        .executable(name: "type-eval", targets: ["type-eval"]),
        .executable(name: "type-repl", targets: ["type-repl"]),
    ],
    dependencies: [
        .package(path: "../LemmaCore"),
        .package(path: "../Lexicon"),
        .package(path: "../Learning"),
    ],
    targets: [
        .target(
            name: "TypeEngine",
            dependencies: [
                .product(name: "LemmaCore", package: "LemmaCore"),
                .product(name: "Lexicon", package: "Lexicon"),
                // Personal-learning integration (M2): `PersonalSnapshot`
                // adapts `Learning.PersonalModel` into the engine's
                // `PersonalVocabulary` seam, and `TypingSession` buffers
                // `Learning.LearningEvent`s (word commits, suggestion
                // accepts, verbatim taps, correction reverts) for the
                // extension to flush into the App Group event log.
                .product(name: "Learning", package: "Learning"),
            ]
        ),
        // Eval-studio shared library: the corpus (dev/heldout.jsonl) reader,
        // the corpus replay runner over the REAL artifacts, the artifact
        // loader, and the explicit EngineConfig override map. Kept as a
        // library (not folded into the type-eval executable) so the JSONL
        // parser and the config-override map are unit-testable — SwiftPM
        // cannot share source files with a test target from an executable.
        .target(
            name: "EvalKit",
            dependencies: [
                "TypeEngine",
                .product(name: "LemmaCore", package: "LemmaCore"),
                .product(name: "Lexicon", package: "Lexicon"),
            ]
        ),
        .executableTarget(
            name: "type-eval",
            dependencies: [
                "TypeEngine",
                "EvalKit",
                .product(name: "LemmaCore", package: "LemmaCore"),
                .product(name: "Lexicon", package: "Lexicon"),
            ],
            resources: [
                .copy("Resources/eval-fixture.tsv")
            ]
        ),
        .executableTarget(
            name: "type-repl",
            dependencies: [
                "TypeEngine",
                .product(name: "LemmaCore", package: "LemmaCore"),
                .product(name: "Lexicon", package: "Lexicon"),
                // `--personal <model.json>` loads a real PersonalModel file.
                .product(name: "Learning", package: "Learning"),
            ]
        ),
        .testTarget(
            name: "TypeEngineTests",
            dependencies: ["TypeEngine"]
        ),
        .testTarget(
            name: "EvalKitTests",
            dependencies: ["EvalKit", "TypeEngine"]
        ),
    ],
    // swift-tools-version 6.0 is required to express `.iOS(.v18)` as a
    // platform (added in PackageDescription 6.0). Pinning the language mode
    // to v5 keeps the existing Swift 5 semantics (no Swift 6 strict
    // concurrency checking) so this stays a pure platform-floor bump, not a
    // concurrency-model migration.
    swiftLanguageModes: [.v5]
)
