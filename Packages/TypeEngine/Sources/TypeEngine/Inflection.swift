import Compression
import Foundation
import Learning
import LemmaCore

// Inflection intelligence, Stage B (PLAN.md "Inflection intelligence"):
// engine consumption of the two Stage-A artifacts —
//
//   * data/is/paradigms.bin   (lemma → forms + feature bundles; form →
//     feature bundles) via LemmaCore.ParadigmsReader,
//   * data/is/governors.json.gz (statistical case government:
//     P(case | previous token) learned from is.lex bigrams × BÍN tags)
//     via GovernorsModel below.
//
// Everything here is RANKING-BOOST form, never hard rules: the morph term is
// a BACKOFF that mainly reorders candidates when exact bigram evidence is
// silent, wrong-form suggestions are offer-only (a valid form of a lemma is
// never auto-replaced by a sibling form — absolute rule), and the personal
// lemma lift is a small additive prior gated on unambiguous lemma
// attribution (the PLAN.md "Lemma-level learning constraint": surface forms
// stay the ground truth; homograph credit never leaks across lemmas).

// MARK: - Paradigms seam

/// Abstraction over the paradigms artifact so tests can inject dictionary-
/// backed fakes (mirrors `MorphologyProviding` standing in front of
/// `BinaryLemmatizer`). Production conformance: `LemmaCore.ParadigmsReader`
/// (see the extension in TypeEngine.swift).
public protocol ParadigmsProviding: AnyObject {
    /// Every lemma group (lemma, pos, gender) whose lemma string equals
    /// `lemma`, with its full form table. [] for unknown lemmas.
    func groups(ofLemma lemma: String) -> [ParadigmGroup]
    /// Every (lemma group, feature bundle) analysis of a surface form,
    /// across all lemma groups. [] for unknown forms.
    func analyses(ofForm form: String) -> [ParadigmAnalysis]
    /// Distinct feature bundles of the form's analyses — the scoring hot
    /// path (once per candidate per keystroke). Default derives from
    /// `analyses`; `ParadigmsReader` overrides with a bundles-only read
    /// that materializes no strings.
    func bundles(ofForm form: String) -> [ParadigmBundle]
}

public extension ParadigmsProviding {
    func bundles(ofForm form: String) -> [ParadigmBundle] {
        var seen = Set<ParadigmBundle>()
        var result: [ParadigmBundle] = []
        for analysis in analyses(ofForm: form) where seen.insert(analysis.bundle).inserted {
            result.append(analysis.bundle)
        }
        return result
    }
}

// MARK: - Governors model

/// The statistical case-government table built by
/// `scripts/build-governors.py`: for every governor token with enough
/// bigram mass and a non-uniform following-case distribution, the observed
/// P(case | governor).
///
/// Representation choice (in-memory dict, NOT a preprocessed binary —
/// deliberate): per governor, the CASE MARGINAL (the primary governed axis;
/// the builder computes its entropy filter on exactly this marginal) plus a
/// compact 16-slot NOUN bundle marginal for the within-case number/
/// definiteness refinement (the Stage-A "bundle_distribution worth it?"
/// question — answer: the case marginal carries most of the signal, but
/// agreement-shaped governors like "þremur"/"miklum" carry a real number
/// preference that only the bundle level sees; adjective bundles stay
/// folded into the case marginal). Total resident table: ~13.7k entries ×
/// (string + 4+16 doubles + mass) ≈ ~3MB of dirty memory, cheap enough
/// that a preprocessed mmap binary (another artifact + format doc + build
/// step for the same lookups) isn't worth its complexity. The one-time
/// gunzip + byte-scan parse (~40 ms release) happens at load, off the
/// keystroke path; revisit as a binary sidecar only if extension launch
/// budgets ever demand it.
public struct GovernorsModel: Sendable {

    public struct Governor: Sendable {
        /// Total (un-split) bigram count that contributed to this governor.
        public let mass: Double
        /// P(case | governor), indexed by `ParadigmBundle` case code
        /// (0=nf, 1=þf, 2=þgf, 3=ef). Sums to ~1.
        public let caseProbabilities: [Double]
        /// Shannon entropy of the case marginal / log2(#cases observed);
        /// 0 = fully deterministic government, 1 = uniform (filtered out
        /// above 0.9 at build time).
        public let caseEntropyRatio: Double
        /// P(noun feature bundle | governor) over the 16 noun slots,
        /// indexed `caseCode | (plural ? 4 : 0) | (definite ? 8 : 0)`, from
        /// the artifact's `bundle_distribution` (noun entries only —
        /// normalized over the WHOLE bundle mass, so slots do not sum to 1
        /// when adjectives carried weight). Powers the within-case
        /// number/definiteness refinement (see `GovernorFit`); nil in
        /// hand-built test tables that only exercise the case marginal.
        public let nounBundleProbabilities: [Double]?

        public init(
            mass: Double,
            caseProbabilities: [Double],
            caseEntropyRatio: Double,
            nounBundleProbabilities: [Double]? = nil
        ) {
            self.mass = mass
            self.caseProbabilities = caseProbabilities
            self.caseEntropyRatio = caseEntropyRatio
            self.nounBundleProbabilities = nounBundleProbabilities
        }
    }

    private let table: [String: Governor]

    public var governorCount: Int { table.count }

    /// Test/fixture entry point.
    public init(table: [String: Governor]) {
        self.table = table
    }

    /// Load `data/is/governors.json.gz`.
    ///
    /// The ~14MB decompression buffer lives in an anonymous `mmap` region
    /// that is `munmap`ed as soon as the scan finishes — a malloc'd buffer
    /// of this size stays DIRTY in the allocator's large-block cache after
    /// free (measured: the pages never came back, even under
    /// `malloc_zone_pressure_relief`), which the extension's jetsam budget
    /// cannot afford. Retained footprint of the whole load is the compact
    /// table only (~1-2MB measured).
    public init(gzippedJSONContentsOf url: URL) throws {
        let compressed = try Data(contentsOf: url, options: .alwaysMapped)
        self.table = try Self.withGunzipped(compressed) { try Self.scanTable($0) }
    }

    /// Parse the (decompressed) governors JSON with a single-pass scanner.
    ///
    /// Deliberately NOT JSONSerialization/JSONDecoder: both materialize the
    /// whole ~14MB document — including the `bundle_distribution` sections
    /// this model drops — as ~half a million transient objects, which
    /// leaves a ~30MB dirty malloc watermark for the process lifetime
    /// (measured in the harness; extension memory discipline forbids it).
    /// The scanner walks the bytes once, retains only the compact table,
    /// and skips each `bundle_distribution` object wholesale. It parses the
    /// machine-generated shape `build-governors.py` emits (compact
    /// separators, string escapes handled defensively); it is not a general
    /// JSON parser.
    public init(jsonData: Data) throws {
        self.table = try jsonData.withUnsafeBytes { raw in
            try Self.scanTable(raw)
        }
    }

    private static func scanTable(_ raw: UnsafeRawBufferPointer) throws -> [String: Governor] {
        var scanner = Scanner(bytes: raw)
        guard scanner.seek(toKey: "governors"), scanner.consume(UInt8(ascii: "{")) else {
            throw GovernorsModelError.malformedJSON
        }
        var table: [String: Governor] = [:]
        table.reserveCapacity(16_384)
        if scanner.consume(UInt8(ascii: "}")) {
            return table
        }
        repeat {
            guard let word = scanner.string(), scanner.consume(UInt8(ascii: ":")),
                scanner.consume(UInt8(ascii: "{"))
            else { throw GovernorsModelError.malformedJSON }
            var mass = 0.0
            var probabilities = [0.0, 0.0, 0.0, 0.0]
            var entropyRatio = 0.0
            var nounBundles: [Double]?
            if !scanner.consume(UInt8(ascii: "}")) {
                repeat {
                    guard let key = scanner.string(), scanner.consume(UInt8(ascii: ":")) else {
                        throw GovernorsModelError.malformedJSON
                    }
                    switch key {
                    case "mass":
                        mass = scanner.number() ?? 0
                    case "case_entropy_ratio":
                        entropyRatio = scanner.number() ?? 0
                    case "case_distribution":
                        guard scanner.consume(UInt8(ascii: "{")) else {
                            throw GovernorsModelError.malformedJSON
                        }
                        if !scanner.consume(UInt8(ascii: "}")) {
                            repeat {
                                guard let name = scanner.string(),
                                    scanner.consume(UInt8(ascii: ":")),
                                    let p = scanner.number()
                                else { throw GovernorsModelError.malformedJSON }
                                if let code = ParadigmBundle.caseNames.firstIndex(of: name) {
                                    probabilities[code] = p
                                }
                            } while scanner.consume(UInt8(ascii: ","))
                            guard scanner.consume(UInt8(ascii: "}")) else {
                                throw GovernorsModelError.malformedJSON
                            }
                        }
                    case "bundle_distribution":
                        // Noun bundles feed the within-case number/
                        // definiteness refinement; adjective bundles are
                        // already folded into the case marginal upstream.
                        guard scanner.consume(UInt8(ascii: "{")) else {
                            throw GovernorsModelError.malformedJSON
                        }
                        if !scanner.consume(UInt8(ascii: "}")) {
                            repeat {
                                guard let key = scanner.string(),
                                    scanner.consume(UInt8(ascii: ":")),
                                    let p = scanner.number()
                                else { throw GovernorsModelError.malformedJSON }
                                if let slot = Self.nounSlot(ofBundleString: key) {
                                    if nounBundles == nil {
                                        nounBundles = [Double](repeating: 0, count: 16)
                                    }
                                    nounBundles![slot] += p
                                }
                            } while scanner.consume(UInt8(ascii: ","))
                            guard scanner.consume(UInt8(ascii: "}")) else {
                                throw GovernorsModelError.malformedJSON
                            }
                        }
                    default:
                        // meta keys / any future key: skip the value
                        // wholesale.
                        guard scanner.skipValue() else {
                            throw GovernorsModelError.malformedJSON
                        }
                    }
                } while scanner.consume(UInt8(ascii: ","))
                guard scanner.consume(UInt8(ascii: "}")) else {
                    throw GovernorsModelError.malformedJSON
                }
            }
            table[word] = Governor(
                mass: mass,
                caseProbabilities: probabilities,
                caseEntropyRatio: entropyRatio,
                nounBundleProbabilities: nounBundles
            )
        } while scanner.consume(UInt8(ascii: ","))
        return table
    }

    /// Noun-slot index of a `bundle_to_string` key ("no:þgf:et:gr" → þgf +
    /// singular + definite); nil for adjective ("lo:…") or malformed keys.
    static func nounSlot(ofBundleString key: String) -> Int? {
        let parts = key.split(separator: ":")
        guard parts.count == 4, parts[0] == "no",
            let code = ParadigmBundle.caseNames.firstIndex(of: String(parts[1]))
        else { return nil }
        var slot = code
        if parts[2] == "ft" { slot |= 4 }
        if parts[3] == "gr" { slot |= 8 }
        return slot
    }

    /// Byte scanner for the governors JSON shape (see `init(jsonData:)`).
    private struct Scanner {
        let bytes: UnsafeRawBufferPointer
        var index = 0

        mutating func skipWhitespace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D: index += 1
                default: return
                }
            }
        }

        /// Consume one expected structural byte (whitespace-tolerant).
        mutating func consume(_ byte: UInt8) -> Bool {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        /// Parse a JSON string at the cursor. Escapes are handled by
        /// byte-skipping (sufficient here: governor words never contain
        /// quotes/backslashes; \uXXXX never appears — the builder writes
        /// ensure_ascii=False).
        mutating func string() -> String? {
            guard consume(UInt8(ascii: "\"")) else { return nil }
            let start = index
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\\") {
                    index += 2
                    continue
                }
                if byte == UInt8(ascii: "\"") {
                    let value = String(decoding: bytes[start..<index], as: UTF8.self)
                    index += 1
                    return value
                }
                index += 1
            }
            return nil
        }

        /// Parse a JSON number at the cursor.
        mutating func number() -> Double? {
            skipWhitespace()
            let start = index
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "0")...UInt8(ascii: "9"),
                    UInt8(ascii: "-"), UInt8(ascii: "+"),
                    UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"):
                    index += 1
                default:
                    return Double(String(decoding: bytes[start..<index], as: UTF8.self))
                }
            }
            return Double(String(decoding: bytes[start..<index], as: UTF8.self))
        }

        /// Skip any JSON value (object/array by depth counting with
        /// in-string tracking, scalars by delimiter scan).
        mutating func skipValue() -> Bool {
            skipWhitespace()
            guard index < bytes.count else { return false }
            let first = bytes[index]
            if first == UInt8(ascii: "{") || first == UInt8(ascii: "[") {
                var depth = 0
                var inString = false
                while index < bytes.count {
                    let byte = bytes[index]
                    if inString {
                        if byte == UInt8(ascii: "\\") { index += 1 }
                        else if byte == UInt8(ascii: "\"") { inString = false }
                    } else {
                        switch byte {
                        case UInt8(ascii: "\""): inString = true
                        case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                        case UInt8(ascii: "}"), UInt8(ascii: "]"):
                            depth -= 1
                            if depth == 0 {
                                index += 1
                                return true
                            }
                        default: break
                        }
                    }
                    index += 1
                }
                return false
            }
            if first == UInt8(ascii: "\"") { return string() != nil }
            // scalar: scan to the next structural delimiter
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"):
                    return true
                default:
                    index += 1
                }
            }
            return false
        }

        /// Advance the cursor past `"<key>":` at the TOP level of the
        /// document (skipping other top-level values wholesale).
        mutating func seek(toKey key: String) -> Bool {
            guard consume(UInt8(ascii: "{")) else { return false }
            repeat {
                guard let found = string(), consume(UInt8(ascii: ":")) else { return false }
                if found == key { return true }
                guard skipValue() else { return false }
            } while consume(UInt8(ascii: ","))
            return false
        }
    }

    /// O(1) governor lookup (callers pass lowercased pipeline words).
    public func governor(of word: String) -> Governor? {
        table[word]
    }

    // MARK: gzip

    enum GovernorsModelError: Error {
        case malformedJSON
        case notGzip
        case corruptGzip
    }

    /// Minimal gzip (RFC 1952) decoder over the Compression framework:
    /// parse/skip the gzip header, inflate the raw-deflate payload
    /// (`COMPRESSION_ZLIB` is raw deflate on Apple platforms) into an
    /// anonymous mmap region sized by the trailer's ISIZE field, hand the
    /// bytes to `body`, then `munmap` — the pages go straight back to the
    /// OS (see `init(gzippedJSONContentsOf:)` for why not malloc).
    /// Sufficient for the pinned artifacts this reads; not a general
    /// streaming decompressor.
    static func withGunzipped<R>(
        _ data: Data, _ body: (UnsafeRawBufferPointer) throws -> R
    ) throws -> R {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> R in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else {
                throw GovernorsModelError.notGzip
            }
            let flags = bytes[3]
            var index = 10
            if flags & 0x04 != 0 {  // FEXTRA
                guard index + 2 <= bytes.count else { throw GovernorsModelError.corruptGzip }
                let extraLength = Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
                index += 2 + extraLength
            }
            if flags & 0x08 != 0 {  // FNAME
                while index < bytes.count, bytes[index] != 0 { index += 1 }
                index += 1
            }
            if flags & 0x10 != 0 {  // FCOMMENT
                while index < bytes.count, bytes[index] != 0 { index += 1 }
                index += 1
            }
            if flags & 0x02 != 0 { index += 2 }  // FHCRC
            guard index < bytes.count - 8 else { throw GovernorsModelError.corruptGzip }

            let uncompressedSize =
                Int(bytes[bytes.count - 4])
                | (Int(bytes[bytes.count - 3]) << 8)
                | (Int(bytes[bytes.count - 2]) << 16)
                | (Int(bytes[bytes.count - 1]) << 24)
            guard uncompressedSize > 0 else { throw GovernorsModelError.corruptGzip }

            let mapped = mmap(
                nil, uncompressedSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
            guard let destination = mapped, destination != MAP_FAILED else {
                throw GovernorsModelError.corruptGzip
            }
            defer { munmap(destination, uncompressedSize) }

            let decoded = compression_decode_buffer(
                destination.assumingMemoryBound(to: UInt8.self),
                uncompressedSize,
                bytes.baseAddress! + index,
                bytes.count - 8 - index,
                nil,
                COMPRESSION_ZLIB
            )
            guard decoded == uncompressedSize else { throw GovernorsModelError.corruptGzip }
            return try body(UnsafeRawBufferPointer(start: destination, count: uncompressedSize))
        }
    }

    /// Test convenience: gunzip to a Data (small fixtures only — copies).
    static func gunzip(_ data: Data) throws -> Data {
        try withGunzipped(data) { Data($0) }
    }
}

// MARK: - Inflection model + engine-internal store

/// The Stage-B artifact pair, injected into a `TypeEngine` via
/// `setInflection(_:)`. Absent by default — every scoring seam below is
/// inert without it (byte-identical to the pre-inflection engine).
public final class InflectionModel: @unchecked Sendable {
    public let paradigms: ParadigmsProviding
    public let governors: GovernorsModel

    public init(paradigms: ParadigmsProviding, governors: GovernorsModel) {
        self.paradigms = paradigms
        self.governors = governors
    }
}

/// Engine-internal mutable holder (same pattern as `PersonalStore`): shared
/// by reference across the engine's corrector, predictor and blended model,
/// so `setInflection` / personal-vocabulary swaps are visible everywhere
/// without an engine rebuild. Confined to the engine's owning queue.
final class InflectionStore {
    private(set) var model: InflectionModel?
    /// Personal lemma lift (LemmaBoostProviding), rebuilt whenever the
    /// personal vocabulary or the inflection model changes.
    private(set) var lift: LemmaBoostProviding?

    func setModel(_ model: InflectionModel?) {
        self.model = model
    }

    /// Rebuild the personal lemma lift from the current personal vocabulary
    /// (lowercased pipeline keys). O(personal scale × paradigm size) — runs
    /// on snapshot swaps and explicit learns, never per keystroke.
    func rebuildLift(words: [String], morphology: MorphologyProviding?, liftNats: Double) {
        guard let model, let morphology, liftNats > 0, !words.isEmpty else {
            lift = nil
            return
        }
        let built = PersonalLemmaLift(
            learnedWords: words,
            morphology: morphology,
            paradigms: model.paradigms,
            liftNats: liftNats
        )
        lift = built.isEmpty ? nil : built
    }

    /// The per-keystroke governor context: non-nil only when the previous
    /// word is a known governor with enough mass and the lane posterior is
    /// Icelandic enough (governors are an Icelandic phenomenon — the gate
    /// keeps English typing byte-identical).
    func governorFit(
        previousWord: String?,
        pIcelandic: Double,
        morphology: MorphologyProviding?,
        config: EngineConfig
    ) -> GovernorFit? {
        guard
            let model,
            config.morphBackoffWeight > 0,
            let previousWord,
            pIcelandic >= config.morphBackoffMinPosterior,
            let governor = model.governors.governor(of: previousWord),
            governor.mass >= config.morphMinGovernorMass
        else { return nil }
        return GovernorFit(
            previousWord: previousWord,
            governor: governor,
            paradigms: model.paradigms,
            morphology: morphology,
            weight: config.morphBackoffWeight,
            floor: config.morphCaseFitFloor
        )
    }
}

// MARK: - Governor fit (the λ_morph backoff term)

/// Precomputed scoring context for one (previous word = governor) lookup.
///
/// The morph term added to a candidate's score is
///
///     λ_morph · log( P(case(candidate) | governor) / 0.25 )
///
/// — a log-likelihood ratio against the uniform 4-case prior, clamped below
/// at `floor` (which also absorbs P = 0), naturally capped above at
/// log(1/0.25) ≈ 1.39. Candidates with no noun/adjective analysis anywhere
/// (English words, verbs, function words, junk) get exactly 0 — an EN
/// sletta after a governor is untouched.
///
/// **Ambiguity rule (documented decision)**: a form with several analyses
/// (syncretism — "hesta" is both þf:ft and ef:ft) is scored by its
/// MAX-probability case under the governor, i.e. the reading the governor
/// makes most likely. The fractional alternative (weighting each analysis
/// by its share, mirroring build-governors.py's fractional-credit rule)
/// was considered and rejected for scoring: it double-penalizes forms whose
/// syncretism happens to span a rare case, and the max rule is the standard
/// Viterbi-style reading for a ranking boost.
///
/// **Backoff placement**: callers add this term ONLY when the exact bigram
/// (governor, candidate) is NOT attested in is.lex — attested bigram
/// evidence already carries the case signal at full corpus strength through
/// `contextualProbability`'s MLE term, and must keep dominating (PLAN.md:
/// "the morph term is the BACKOFF for unseen noun-governor pairs").
struct GovernorFit {
    let previousWord: String
    let governor: GovernorsModel.Governor
    let paradigms: ParadigmsProviding
    let morphology: MorphologyProviding?
    let weight: Double
    /// Clamped log(P(case)/0.25) per case code — precomputed once per
    /// keystroke (this struct is built once per correct()/rank() call and
    /// probed once per candidate).
    let caseLogRatios: [Double]
    /// Case code with the highest governed probability.
    let dominantCaseCode: Int

    /// Within-case number/definiteness refinement for noun bundles, in
    /// nats, indexed by noun slot (caseCode | plural<<2 | definite<<3):
    /// log(P(number,definiteness | case, governor) / 0.25), clamped to
    /// [floor, log 4]. nil when the governor has no noun bundle marginal
    /// (hand-built test tables) — scoring degrades to the case marginal.
    let nounSlotRefinements: [Double]?

    init(
        previousWord: String,
        governor: GovernorsModel.Governor,
        paradigms: ParadigmsProviding,
        morphology: MorphologyProviding?,
        weight: Double,
        floor: Double
    ) {
        self.previousWord = previousWord
        self.governor = governor
        self.paradigms = paradigms
        self.morphology = morphology
        self.weight = weight
        self.caseLogRatios = governor.caseProbabilities.map { p in
            p > 0 ? max(log(p / 0.25), floor) : floor
        }
        var best = 0
        for code in 1..<4
        where governor.caseProbabilities[code] > governor.caseProbabilities[best] {
            best = code
        }
        self.dominantCaseCode = best
        if let bundleProbabilities = governor.nounBundleProbabilities {
            // Normalize the noun slots within each case so the refinement
            // is a clean P(number,def | case) against its uniform 1/4
            // prior — independent of how much of the case's mass was
            // adjectives.
            var caseNounTotals = [0.0, 0.0, 0.0, 0.0]
            for slot in 0..<16 { caseNounTotals[slot & 0x3] += bundleProbabilities[slot] }
            var refinements = [Double](repeating: floor, count: 16)
            for slot in 0..<16 {
                let total = caseNounTotals[slot & 0x3]
                guard total > 0, bundleProbabilities[slot] > 0 else { continue }
                refinements[slot] = min(
                    max(log((bundleProbabilities[slot] / total) / 0.25), floor),
                    log(4)
                )
            }
            self.nounSlotRefinements = refinements
        } else {
            self.nounSlotRefinements = nil
        }
    }

    /// The backoff term for one candidate, in nats (0 when the candidate
    /// has no noun/adjective reading anywhere). Per analysis:
    ///
    ///   case term   log(P(case | governor) / 0.25)          (nouns + adj)
    /// + noun term   log(P(number,def | case, gov) / 0.25)   (nouns, when
    ///                                                        the governor
    ///                                                        has a bundle
    ///                                                        marginal)
    ///
    /// and the candidate scores its BEST analysis (max-probability-bundle
    /// rule — see the type doc). Forms absent from the frequency-filtered
    /// paradigms.bin fall back to `lemmatizeWithMorph` cases via
    /// MorphologyProviding (case term only).
    func fitNats(for word: String) -> Double {
        let bundles = paradigms.bundles(ofForm: word)
        if !bundles.isEmpty {
            var best = -Double.infinity
            for bundle in bundles {
                var fit = caseLogRatios[bundle.caseCode]
                if bundle.pos == .noun, let refinements = nounSlotRefinements {
                    let slot =
                        bundle.caseCode
                        | (bundle.isPlural ? 4 : 0)
                        | (bundle.isDefinite ? 8 : 0)
                    fit += refinements[slot]
                }
                if fit > best { best = fit }
            }
            return weight * best
        }
        guard let morphology else { return 0 }
        var best = -Double.infinity
        for name in morphology.nounAdjectiveCases(of: word) {
            if let code = ParadigmBundle.caseNames.firstIndex(of: name),
                caseLogRatios[code] > best
            {
                best = caseLogRatios[code]
            }
        }
        guard best > -Double.infinity else { return 0 }
        return weight * best
    }

    /// Wrong-form machinery (offer-only — PLAN.md Stage B #2): the typed
    /// word is VALID but every reading of it fits the governor much worse
    /// than the governor's dominant case; return the paradigm SIBLING forms
    /// of the same lemma in the dominant case, holding every other feature
    /// axis (number, definiteness, gender/degree/strength) fixed at the
    /// typed word's best reading — "frá hestur" (no:nf:et:ngr) → target
    /// no:þgf:et:ngr → "hesti". Empty when the typed word already has a
    /// dominant-case reading, the advantage is below `minAdvantage` (in
    /// nats of case log-ratio), or paradigms.bin has no analysis (the
    /// morphology fallback cannot GENERATE siblings, so it does not apply
    /// here).
    func wrongFormSiblings(ofValidTyped typed: String, minAdvantage: Double) -> [String] {
        let analyses = paradigms.analyses(ofForm: typed)
        guard !analyses.isEmpty else { return [] }
        let ratios = caseLogRatios
        let dominant = dominantCaseCode
        // Max-probability-bundle rule: the typed word's fit is its best
        // reading's fit; if any reading is already the dominant case there
        // is nothing to offer.
        guard
            let best = analyses.max(by: {
                ratios[$0.bundle.caseCode] < ratios[$1.bundle.caseCode]
            })
        else { return [] }
        guard best.bundle.caseCode != dominant else { return [] }
        guard ratios[dominant] - ratios[best.bundle.caseCode] >= minAdvantage else { return [] }

        let target = best.bundle.replacingCase(dominant)
        var siblings: [String] = []
        for group in paradigms.groups(ofLemma: best.lemma)
        where group.pos == best.pos && group.genderCode == best.genderCode {
            for form in group.forms
            where form.bundle == target && form.form != typed && !siblings.contains(form.form) {
                siblings.append(form.form)
            }
        }
        return siblings
    }
}

// MARK: - Personal lemma lift (LemmaBoostProviding)

/// The concrete `Learning.LemmaBoostProviding` conformance — the wave-2
/// engine-side implementation the protocol stub promised (see its doc):
/// lemma generalization as a ranking boost, computed here where LemmaCore
/// is available, with counts staying surface-keyed in `PersonalModel`.
///
/// Build-time derivation (rebuilt on snapshot swaps / explicit learns):
///
///  1. For each learned surface form, ask BÍN for its lemma candidates
///     (`lemmatize` semantics via `MorphologyProviding.lemmaCandidates`).
///     Only forms with EXACTLY ONE distinct lemma lift — the hard
///     constraint verbatim ("lift ... only when the form is
///     lemma-unambiguous"); ambiguous forms ("á") never lift.
///  2. Enumerate that lemma's paradigm siblings from paradigms.bin, and
///     keep only siblings whose OWN lemma attribution is also unambiguous
///     (a sibling shared with another lemma would leak homograph credit —
///     the protocol's "return 1.0 whenever lemma attribution is ambiguous").
///
/// Query time is then an O(1) set probe per candidate. The boost is
/// `exp(liftNats)` — multiplicative per the protocol, consumed as
/// `log(lemmaBoost(...))` nats inside `BlendedLanguageModel.personalBoost`,
/// and `liftNats` (EngineConfig.lemmaLiftBoost) must stay below
/// `personalBoostBase` so a sibling never outranks the learned form itself.
final class PersonalLemmaLift: LemmaBoostProviding, @unchecked Sendable {

    /// Lowercased learned surface forms — never lift themselves (they carry
    /// their own, larger personal boost).
    private let learnedKeys: Set<String>
    /// Lowercased paradigm-sibling forms eligible for the lift.
    private let siblingKeys: Set<String>
    private let multiplier: Double

    var isEmpty: Bool { siblingKeys.isEmpty }

    init(
        learnedWords: [String],
        morphology: MorphologyProviding,
        paradigms: ParadigmsProviding,
        liftNats: Double
    ) {
        var learned = Set<String>()
        var siblings = Set<String>()
        for word in learnedWords {
            let key = word.lowercased()
            learned.insert(key)
            let lemmas = morphology.lemmaCandidates(of: key)
            // The constraint gate: single-lemma forms only.
            guard lemmas.count == 1, let lemma = lemmas.first else { continue }
            for group in paradigms.groups(ofLemma: lemma) {
                for form in group.forms {
                    let formKey = form.form  // paradigms strings are lowercase
                    guard !siblings.contains(formKey) else { continue }
                    // Sibling-side ambiguity gate: the sibling itself must
                    // attribute to exactly one lemma.
                    let attributions = Set(paradigms.analyses(ofForm: formKey).map(\.lemma))
                    guard attributions == [lemma] else { continue }
                    siblings.insert(formKey)
                }
            }
        }
        self.learnedKeys = learned
        self.siblingKeys = siblings.subtracting(learned)
        self.multiplier = exp(liftNats)
    }

    func lemmaBoost(forCandidate surfaceForm: String) -> Double {
        let key = surfaceForm.lowercased()
        guard !learnedKeys.contains(key) else { return 1 }
        return siblingKeys.contains(key) ? multiplier : 1
    }
}
