// swift-tools-version: 6.0
import PackageDescription

// Headless macOS replay of the keyboard extension's launch path against the
// REAL data/ artifacts. See tools/cold-start/README.md ("Launch probe").
//
// The `launch-probe` target compiles the pure-Foundation KeyboardExt sources
// it exercises (EmojiCatalog, EmojiFrequencyStore, IcelandicEmojiSuggester,
// IcelandicEmojiSearch) through symlinks in Sources/launch-probe, so those
// phases measure the shipping code, not a copy. `ISEmojiView` here is a
// three-type shim (Category / Emoji / EmojiCategory) standing in for the
// iOS-only vendored package those files import.
let package = Package(
    name: "launch-probe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../../Packages/TypeEngine"),
        .package(path: "../../../Packages/LemmaCore"),
        .package(path: "../../../Packages/Lexicon"),
        .package(path: "../../../Packages/Learning"),
    ],
    targets: [
        .target(name: "ISEmojiView"),
        .executableTarget(
            name: "launch-probe",
            dependencies: [
                "ISEmojiView",
                .product(name: "TypeEngine", package: "TypeEngine"),
                .product(name: "LemmaCore", package: "LemmaCore"),
                .product(name: "Lexicon", package: "Lexicon"),
                .product(name: "Learning", package: "Learning"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
