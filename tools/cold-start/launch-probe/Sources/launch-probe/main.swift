// launch-probe: replay the keyboard extension's launch path, headless, on
// macOS, against the real data/ artifacts, and report per-phase wall time plus
// `phys_footprint` deltas — the metric the iOS jetsam cap watches.
//
// What this mirrors (keep in sync with the sources it names):
//   * `LyklabordAutocompleteService.bootstrapIfNeeded` — phases 1–6, in the
//     same order, same artifact set, same engine calls (the service itself
//     imports KeyboardKit and cannot be compiled here; the ordering is also
//     guarded by tools/cold-start/launch_path_lint.py).
//   * `LyklabordAutocompleteService.scheduleEmojiSuggesterLoad` — phase 7.
//   * `LyklabordAutocompleteService.scheduleInflectionLoad` — phase 10.
//   * `KeyboardViewController.viewWillAppear` — phase 11, which compiles the
//     REAL EmojiCatalog/EmojiFrequencyStore sources via symlinks.
//   * `IcelandicEmojiSearchSession.refresh` — phase 12.
//   * A second controller in a surviving process — phase 13.
//
// Output: one JSON object on stdout (schema `lyklabord.launch-probe.v1`),
// human-readable phase table on stderr. Exit 0 always; gating is done by
// tools/cold-start/launch_probe_report.py over several fresh processes.
//
// This is a macOS regression alarm. Absolute numbers do NOT forecast an
// iPhone: different CPU, different page cache state, no dyld/UIKit/SwiftUI
// cost, Mac `phys_footprint` accounting differs. Trends and ratios transfer.

import Foundation
import Learning
import LemmaCore
import Lexicon
import TypeEngine

// MARK: - Measurement helpers

func physFootprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
}

var phases: [[String: Any]] = []
var peakFootprint = physFootprintBytes()
let processStartFootprint = peakFootprint

func stderr(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

@discardableResult
func phase<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
    let before = physFootprintBytes()
    let start = ContinuousClock.now
    let result = try body()
    let ms = Double((ContinuousClock.now - start).components.attoseconds) / 1e15
        + Double((ContinuousClock.now - start).components.seconds) * 1000
    let after = physFootprintBytes()
    peakFootprint = max(peakFootprint, after)
    let deltaMB = (Double(after) - Double(before)) / 1_048_576
    phases.append(["name": name, "ms": ms, "footprintDeltaMB": deltaMB])
    stderr(String(format: "%-44@ %8.2f ms  Δfootprint %+7.2f MB  (%.1f MB)", name as NSString, ms, deltaMB, Double(after) / 1_048_576))
    return result
}

func repoRoot() -> URL {
    var dir = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { dir = dir.deletingLastPathComponent() }  // …/tools/cold-start/launch-probe/Sources/launch-probe/main.swift
    precondition(
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("data/is/is.lex").path),
        "repo root not found from \(#filePath)")
    return dir
}

let root = repoRoot()
let data = root.appendingPathComponent("data")
func artifact(_ rel: String) -> URL { data.appendingPathComponent(rel) }

// MARK: - Phases 1–7: service bootstrap (mirror of bootstrapIfNeeded)

struct Bootstrapped {
    let engine: TypeEngine
    let session: TypingSession
    let curated: CuratedVocabulary?
    let emojiSuggester: IcelandicEmojiSuggester?
}

func bootstrap(label: String) throws -> Bootstrapped {
    let english = try phase("\(label) 1 open en.lex + is.lex (mmap)") {
        () -> (FrequencyLexicon, FrequencyLexicon) in
        (try FrequencyLexicon(contentsOf: artifact("en/en.lex")),
         try FrequencyLexicon(contentsOf: artifact("is/is.lex")))
    }
    let calibration = phase("\(label) 1b calibration profiles (JSON)") {
        (try? LexiconCalibrationProfile(contentsOf: artifact("en/en-calibration.json")),
         try? LexiconCalibrationProfile(contentsOf: artifact("is/is-calibration.json")))
    }
    let morphology = phase("\(label) 2 bin-morph.bin + folded (mmap)") { () -> BinaryLemmatizer? in
        guard let m = try? BinaryLemmatizer(contentsOf: artifact("is/bin-morph.bin")) else { return nil }
        try? m.loadFoldedIndex(contentsOf: artifact("is/bin-morph.folded.bin"))
        return m
    }
    let engine = phase("\(label) 3 TypeEngine init") {
        TypeEngine(
            icelandic: english.1, english: english.0, morphology: morphology,
            icelandicCalibration: calibration.1, englishCalibration: calibration.0)
    }
    phase("\(label) 4 engine.warmUp (page-fault spread)") { engine.warmUp() }
    let curated = phase("\(label) 5 extra-vocab.txt (curated)") {
        CuratedVocabulary(contentsOf: artifact("is/extra-vocab.txt"))
    }
    let session = phase("\(label) 6 setPersonalVocabulary + TypingSession") { () -> TypingSession in
        engine.setPersonalVocabulary(curated)
        return TypingSession(engine: engine)
    }
    return Bootstrapped(engine: engine, session: session, curated: curated, emojiSuggester: nil)
}

/// Mirrors `scheduleEmojiSuggesterLoad`: runs on the auxiliary queue AFTER
/// the session is published, so it is measured but excluded from engine-ready.
func loadEmojiSuggester(label: String) -> IcelandicEmojiSuggester? {
    phase("\(label) 7 is-suggestions.json (post-publish, auxiliary queue)") {
        IcelandicEmojiSuggester(contentsOf: artifact("emoji/is-suggestions.json"))
    }
}

let bootstrapStart = ContinuousClock.now
var cold = try bootstrap(label: "cold")
let engineReadyMs = Double((ContinuousClock.now - bootstrapStart).components.attoseconds) / 1e15
    + Double((ContinuousClock.now - bootstrapStart).components.seconds) * 1000
stderr(String(format: "→ engine ready (phases 1–6): %.2f ms", engineReadyMs))
cold = Bootstrapped(
    engine: cold.engine, session: cold.session, curated: cold.curated,
    emojiSuggester: loadEmojiSuggester(label: "cold"))

// MARK: - Phase 8: first keystrokes (what the first autocomplete pass costs)

// Typed windows a user plausibly produces right after the keyboard appears.
// Each pass is timed individually; the FIRST one is the cold number the
// device journal records as firstRequestToStableResultMs' engine share.
let windows = ["h", "ha", "hal", "hall", "halló", "halló ", "halló þ", "halló þe", "halló þet", "halló þett", "halló þetta"]
var keystrokeMs: [Double] = []
for window in windows {
    let start = ContinuousClock.now
    _ = cold.session.suggestions(for: window, limit: 4)
    _ = cold.emojiSuggester?.suggestion(for: TypingSession.splitCurrentWord(of: window).currentWord)
    let elapsed = ContinuousClock.now - start
    keystrokeMs.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
}
peakFootprint = max(peakFootprint, physFootprintBytes())
stderr(String(format: "→ first keystroke %.2f ms; worst of first %d: %.2f ms", keystrokeMs[0], windows.count, keystrokeMs.max() ?? 0))

// MARK: - Phase 9: personal model (what viewWillAppear's refresh reloads)

// Synthetic App Group model near the size a long-time user accumulates:
// user-added words only (the public API available here); it exercises the
// same JSON decode + snapshot + composite swap as reloadPersonalSnapshotIfChanged.
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lyklabord-launch-probe-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let modelURL = tmp.appendingPathComponent("personal-model.json")
let fixtureWordCount = 1_500
phase("personal fixture write (\(fixtureWordCount) words, not launch)") {
    let model = PersonalModel()
    for i in 0..<fixtureWordCount {
        try? model.addUserWord("orð\(i)fixture")
    }
    try? model.save(to: modelURL)
}
phase("9 personal-model.json load + snapshot swap") {
    if let model = try? CoordinatedFileAccess.coordinateRead(at: modelURL, byAccessor: { try PersonalModel(contentsOf: $0) }) {
        let snapshot = PersonalSnapshot(model: model)
        if let curated = cold.curated {
            cold.engine.setPersonalVocabulary(CompositeVocabulary(curated: curated, personal: snapshot))
        } else {
            cold.engine.setPersonalVocabulary(snapshot)
        }
        let touch = PersonalTouchSnapshot(model: model)
        cold.engine.setPersonalTouch(touch.isEmpty ? nil : touch)
    }
}

// MARK: - Phase 10: inflection (scheduleInflectionLoad, off-queue then setInflection)

func loadInflection(label: String) -> InflectionModel? {
    phase(label) { () -> InflectionModel? in
        guard let paradigms = try? ParadigmsReader(contentsOf: artifact("is/paradigms.bin")),
            let governors = try? GovernorsModel(gzippedJSONContentsOf: artifact("is/governors.json.gz"))
        else { return nil }
        return InflectionModel(paradigms: paradigms, governors: governors)
    }
}
let inflectionBefore = physFootprintBytes()
let inflection = loadInflection(label: "10 paradigms.bin + governors.json.gz (gunzip+scan)")
phase("10b engine.setInflection") { cold.engine.setInflection(inflection) }
let inflectionRetainedMB = (Double(physFootprintBytes()) - Double(inflectionBefore)) / 1_048_576

// MARK: - Phase 11: presentation path (viewWillAppear → toolbar frecency row)

// This is the REAL KeyboardExt code (symlinked sources). `EmojiCatalog.shared`
// resolves via Bundle.main in the extension; here the same decoder runs on the
// repo artifact. The frecency store is seeded with 12 personal emoji so the
// `top(8)` availability filter runs over personal + seed entries, as it does
// for a real user.
let catalog = try phase("11 EmojiCatalog decode (catalog.json)") {
    try EmojiCatalog(data: Data(contentsOf: artifact("emoji/catalog.json"), options: .mappedIfSafe))
}
let probeDefaults = UserDefaults(suiteName: "is.solberg.lyklabord.launch-probe")!
probeDefaults.removePersistentDomain(forName: "is.solberg.lyklabord.launch-probe")
let store = EmojiFrequencyStore(defaults: probeDefaults)
let availability: (String) -> Bool = { catalog.isAvailable($0) }
phase("11a frecency store seed (12 records, not launch)") {
    for e in ["🤔", "🫠", "🥹", "😶‍🌫️", "🧑‍💻", "🇮🇸", "🫶", "🍕", "☕️", "🚀", "🌧️", "🫡"] {
        // `record` consults EmojiCatalog.shared (Bundle.main) in production;
        // the availability guard falls through to `true` here, which is fine
        // for seeding.
        store.record(e)
    }
}
let presentationStart = ContinuousClock.now
let top8 = phase("11b viewWillAppear: EmojiFrequencyStore.top(8)") { store.top(8, availability: availability) }
let presentationMs = Double((ContinuousClock.now - presentationStart).components.attoseconds) / 1e15
    + Double((ContinuousClock.now - presentationStart).components.seconds) * 1000
precondition(top8.count == 8, "frecency row must fill 8 slots")
phase("11c emoji key long-press: top(10)") { _ = store.top(10, availability: availability) }
phase("11d emoji picker open: pickerCategories") { _ = catalog.pickerCategories() }

// MARK: - Phase 12: emoji search open + first query

let searchIndex = try phase("12 is-search.json decode") {
    try IcelandicEmojiSearchIndex(data: Data(contentsOf: artifact("emoji/is-search.json"), options: .mappedIfSafe))
}
phase("12a search: empty query frecency (24)") {
    for (i, e) in store.top(24, availability: availability).enumerated() {
        _ = searchIndex.frecencyResult(for: e, order: i)
    }
}
phase("12b search: 'hjarta' + 'kaffi' + folded miss") {
    _ = searchIndex.search("hjarta")
    _ = searchIndex.search("kaffi")
    _ = searchIndex.search("zzqx")
}

// MARK: - Phase 13: second controller in a surviving process

// iOS re-creates KeyboardViewController in a live extension process (journal
// samples with processServiceOrdinal > 1). Each new controller builds a new
// service and re-bootstraps. The engine part is cheap (mmap re-open); the
// inflection reload used to repeat the 14 MB gunzip transient + a second
// governors table until the process-wide cache in
// LyklabordAutocompleteService.scheduleInflectionLoad. Both are measured
// here: the uncached reload (what a second controller cost before) and the
// cached path (what it costs now: a pointer).
let secondStart = ContinuousClock.now
let secondBefore = physFootprintBytes()
let warm = try bootstrap(label: "2nd-controller")
let secondBootstrapMs = Double((ContinuousClock.now - secondStart).components.attoseconds) / 1e15
    + Double((ContinuousClock.now - secondStart).components.seconds) * 1000
let uncachedBefore = physFootprintBytes()
let inflection2 = loadInflection(label: "13 inflection reload UNCACHED (pre-fix behaviour)")
let inflectionReloadRetainedMB = (Double(physFootprintBytes()) - Double(uncachedBefore)) / 1_048_576
phase("13a setInflection (shared model, cached path)") { warm.engine.setInflection(inflection) }
_ = inflection2
let secondControllerRetainedMB = (Double(physFootprintBytes()) - Double(secondBefore)) / 1_048_576
stderr(String(format: "→ second bootstrap (engine only): %.2f ms; retained by 2nd controller incl. uncached inflection: %+.2f MB", secondBootstrapMs, secondControllerRetainedMB))

// MARK: - Report

let finalFootprint = physFootprintBytes()
peakFootprint = max(peakFootprint, finalFootprint)
let report: [String: Any] = [
    "schema": "lyklabord.launch-probe.v1",
    "capturedAt": Date().timeIntervalSince1970,
    "host": [
        "platform": "macOS",
        "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
        "model": {
            var system = utsname(); uname(&system)
            return withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }(),
        "note": "macOS regression alarm; absolute values do not forecast iOS",
    ],
    "summary": [
        "engineReadyMs": engineReadyMs,
        "firstKeystrokeMs": keystrokeMs[0],
        "worstEarlyKeystrokeMs": keystrokeMs.max() ?? 0,
        "presentationMainThreadMs": presentationMs,
        "inflectionRetainedMB": inflectionRetainedMB,
        "inflectionReloadUncachedRetainedMB": inflectionReloadRetainedMB,
        "secondBootstrapMs": secondBootstrapMs,
        "secondControllerRetainedMB": secondControllerRetainedMB,
        "processStartFootprintMB": Double(processStartFootprint) / 1_048_576,
        "peakFootprintMB": Double(peakFootprint) / 1_048_576,
        "finalFootprintMB": Double(finalFootprint) / 1_048_576,
    ],
    "keystrokeMs": keystrokeMs,
    "phases": phases,
]
let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
print(String(decoding: json, as: UTF8.self))
