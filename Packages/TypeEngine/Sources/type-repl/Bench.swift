import Foundation
import TypeEngine

/// Latency regression gate: replay a fixed mixed IS/EN text keystroke-by-
/// keystroke through the proxy + session (identical path to the extension)
/// and report per-keystroke `suggestions()` latency percentiles.
struct Bench {
    let engine: TypeEngine

    /// Built-in mixed Icelandic/English text, ~200 keystrokes. Chosen to
    /// exercise: IS morphology, EN words, posterior drift both ways, commits
    /// via space and period, and a few misspellings that walk the edits2
    /// path (worst case).
    static let text =
        "góðan daginn hvernig hefur þú það ég er að læra íslensku. "
        + "today was busy but the weather is nice. "
        + "ég ætla að borða hádegismat with my friends núna. "
        + "sjáumst síðar have a good day takk fyrir hjálpina. "
        + "þetta er frábært veðrur og ég er hamingjusamur bless"

    /// Worst-case line: an unknown hyphenated word whose PARTS are also
    /// unknown, so the compound rule can't validate it and nearly every
    /// mid-word keystroke walks the full (budgeted) edits2 path. Before the
    /// edits2 wall-clock budget this took 300–2000 ms/keystroke; the gate
    /// is <30 ms/keystroke.
    static let edits2WorstCase = "brgha-þwkkt"

    /// Beam-decoder line (dogfood 2026-07-15): "koetip" = kortið with two
    /// adjacent-key substitutions (e→r, p→ð). Under generate-and-test
    /// edits2 the final keystroke took ~31 ms and never found kortið; the
    /// prefix-range beam must decode it inside the extension's per-
    /// keystroke budget (<8 ms).
    static let beamWorstCase = "Mávahlíð er komin á koetip"

    func run(limit: Int) {
        // Production-shaped warm-up: the extension calls engine.warmUp()
        // from its bootstrap. First-keystroke latencies below therefore
        // reflect what a user sees after the keyboard loads.
        let warmStart = ContinuousClock.now
        engine.warmUp()
        let warmMs = warmStart.duration(to: .now).milliseconds

        let typist = Typist(engine: engine, limit: limit)
        typist.reset()

        let total = ContinuousClock.now
        typist.type(Self.text)
        let wall = total.duration(to: .now)

        let raw = typist.latenciesMicros
        let latencies = raw.sorted()
        guard !latencies.isEmpty else {
            print("no keystrokes measured")
            return
        }

        func percentile(_ p: Double) -> Double {
            let rank = p * Double(latencies.count - 1)
            let low = Int(rank.rounded(.down))
            let high = Int(rank.rounded(.up))
            let fraction = rank - Double(low)
            return latencies[low] * (1 - fraction) + latencies[high] * fraction
        }

        print("type-repl bench — \(raw.count) keystrokes, limit \(limit)")
        print("  warmUp()           \(String(format: "%.1f", warmMs)) ms")
        print("  wall time          \(String(format: "%.1f", wall.milliseconds)) ms")
        print("  p50                \(String(format: "%8.0f", percentile(0.50))) us")
        print("  p95                \(String(format: "%8.0f", percentile(0.95))) us")
        print("  p99                \(String(format: "%8.0f", percentile(0.99))) us")
        print("  max                \(String(format: "%8.0f", latencies.last!)) us")
        // Cold-start gate: page faults on first keystrokes (PLAN.md quirk
        // list) — warmUp() should keep this close to the steady state.
        let firstMax = raw.prefix(5).max() ?? 0
        print("  first-5 max        \(String(format: "%8.0f", firstMax)) us")
        print("  words committed    \(typist.session.committedWordCount)")
        print("  posterior updates  \(typist.session.posteriorUpdateCount)")
        print("  final P(IS)        \(String(format: "%.3f", typist.session.probabilityIcelandic))")

        // The slowest keystrokes, for eyeballing edits2 outliers.
        let slowest = latencies.suffix(5).map { String(format: "%.0f", $0) }
        print("  slowest 5          [\(slowest.joined(separator: " "))] us")

        // Separate worst-case gate (see edits2WorstCase docs above). Kept
        // out of the main percentiles so those stay representative of
        // typical typing.
        typist.reset()
        typist.type(Self.edits2WorstCase)
        let worst = typist.latenciesMicros.max() ?? 0
        print(
            "  edits2 worst case  \(String(format: "%8.0f", worst)) us"
                + "  (slowest keystroke while typing \"\(Self.edits2WorstCase)\")"
        )

        // Beam-decoder gate (see beamWorstCase docs above): the koetip
        // dogfood sentence, slowest keystroke — the deep multi-edit decode
        // fires on the unknown token's last keystrokes.
        typist.reset()
        typist.type(Self.beamWorstCase)
        let beamWorst = typist.latenciesMicros.max() ?? 0
        print(
            "  beam worst case    \(String(format: "%8.0f", beamWorst)) us"
                + "  (slowest keystroke while typing \"…á koetip\")"
        )
    }
}
