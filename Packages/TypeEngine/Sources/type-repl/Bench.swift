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

    /// Lane-relaxation line: a fully accent-naked Icelandic sentence (only
    /// the long-press acutes stripped; ð/ö keep their dedicated keys) typed
    /// after an Icelandic warm-up sentence saturates the lane — every
    /// naked word walks the fold-priced decode. Fold pricing is O(1) per
    /// beam expansion, so this must stay in the ordinary-typing ballpark.
    static let accentNakedWarmup = "við erum að versla fyrir helgina. "
    static let accentNakedCase = "flytjum i bud fyrir helgina og faum okkur kaffi a eftir"

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

        // Lane-relaxation gate (see accentNakedCase docs): a fully
        // accent-naked IS sentence decoded inside a saturated lane.
        typist.reset()
        typist.type(Self.accentNakedWarmup)
        let nakedStart = typist.latenciesMicros.count
        typist.type(Self.accentNakedCase)
        let nakedLatencies = typist.latenciesMicros[nakedStart...].sorted()
        let nakedWorst = nakedLatencies.last ?? 0
        let nakedP50 = nakedLatencies.isEmpty ? 0 : nakedLatencies[nakedLatencies.count / 2]
        print(
            "  accent-naked IS    \(String(format: "%8.0f", nakedWorst)) us"
                + "  (slowest; p50 \(String(format: "%.0f", nakedP50)) us"
                + " while typing \"flytjum i bud …\" at P(IS)≈0.9)"
        )

        // Inflection-intelligence gate (PLAN.md "Inflection intelligence"):
        // every mid-word keystroke here runs with a governor as the
        // previous word ("frá"/"til"/"um" all clear the mass gate), so the
        // per-keystroke cost of the morph backoff (O(1) governor lookup +
        // one paradigms/bigram probe per candidate) is fully exercised.
        typist.reset()
        typist.type("við komum frá húsinu og fórum til borgarinnar um miðnætti. ")
        let inflectStart = typist.latenciesMicros.count
        typist.type("ég fer frá hestinum til kirkjunnar um helgina")
        let inflectLatencies = typist.latenciesMicros[inflectStart...].sorted()
        let inflectWorst = inflectLatencies.last ?? 0
        let inflectP50 = inflectLatencies.isEmpty ? 0 : inflectLatencies[inflectLatencies.count / 2]
        print(
            "  governor-context   \(String(format: "%8.0f", inflectWorst)) us"
                + "  (slowest; p50 \(String(format: "%.0f", inflectP50)) us"
                + " while typing after frá/til/um governors)"
        )

        // Memory footprint after everything above (mmap discipline gate:
        // paradigms.bin/lemma-is.bin resident cost is touched pages only;
        // the governors table is the one deliberate dirty allocation).
        let memory = Self.memoryFootprint()
        print(
            "  phys_footprint     \(String(format: "%8.1f", Double(memory.footprint) / 1024 / 1024)) MB"
                + "  (resident \(String(format: "%.1f", Double(memory.resident) / 1024 / 1024)) MB"
                + " after bench, all artifacts loaded)"
        )
    }

    static func memoryFootprint() -> (resident: UInt64, footprint: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        return (info.resident_size, UInt64(info.phys_footprint))
    }
}
