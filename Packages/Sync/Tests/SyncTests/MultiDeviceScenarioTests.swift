import XCTest
import Learning
@testable import Sync

/// Seeded multi-device simulation: N devices, each with a REAL
/// `PersonalModel` + `EventLog` on disk, mutate independently (commits on
/// random days, taps, deletions, user adds), sync in random order through
/// one `InMemoryCloudStore` / `InMemoryKeyStore` (= one iCloud account),
/// and the harness checks the cross-device promises after every round:
///
/// - convergence: after every device has synced twice with no mutations in
///   between, all payloads are identical;
/// - deletions stick: once ANY device deleted `w`, `w` is never learned on
///   any device after that device's next sync (unless explicitly re-added
///   — which, see `FoundBugTests`, cannot win today, so the invariant is
///   checked on words that were never re-added);
/// - no inflation: a word's merged count never exceeds the total number of
///   organic commits across all devices (max-not-sum must not double count
///   through ping-pong);
/// - clock skew: a word committed on day D on one device and D+1 on another
///   merges to a learned word (documented: distinct buckets ≈ distinct
///   days, regardless of which device saw them).
///
/// Reproduce: `LEARNING_PROPERTY_SEED=<seed>`; soak: `LEARNING_PROPERTY_ITERATIONS=<n>`.
final class MultiDeviceScenarioTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MultiDevice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private static let alphabet = ["jökull", "Jökull", "hús", "hestur", "þú", "æði", "the", "his", "prófílmynd", "köttur"]

    /// One simulated device.
    private final class Device {
        let name: String
        let modelURL: URL
        /// Read/compact handle; appends go through a per-call log with the
        /// scenario's day injected (see `commit`/`tap`).
        let log: EventLog
        var model: PersonalModel
        var removed = Set<String>()
        var organicCommits: [String: Int] = [:]

        init(name: String, directory: URL) throws {
            self.name = name
            modelURL = directory.appendingPathComponent("\(name).json")
            log = EventLog(url: directory.appendingPathComponent("\(name).log"), dayProvider: { 20_000 })
            model = PersonalModel()
            try model.save(to: modelURL)
        }

        func commit(_ word: String, day: Int32) throws {
            let dayLog = EventLog(url: log.url, dayProvider: { day })
            try dayLog.append(.wordCommitted(word: word, previousWord: nil, languageHint: .icelandic))
            organicCommits[word, default: 0] += 1
        }

        func tap(_ word: String, day: Int32) throws {
            let dayLog = EventLog(url: log.url, dayProvider: { day })
            try dayLog.append(.wordTapped(word: word))
            organicCommits[word, default: 0] += 1
        }

        func compact() throws {
            try model.compactAndSave(applying: log, to: modelURL)
        }

        func payload() throws -> SyncPayload {
            try PersonalModelDocument(decoding: Data(contentsOf: modelURL)).payload
        }

        /// Apply a sync outcome exactly as the app does: write back and reload.
        func apply(_ outcome: SyncOutcome) throws {
            switch outcome {
            case .pulled(let data), .merged(let data), .failed(_, let data?):
                try data.write(to: modelURL, options: .atomic)
                model = try PersonalModel(contentsOf: modelURL)
            default:
                break
            }
        }
    }

    private func sync(_ device: Device, store: InMemoryCloudStore, keyStore: InMemoryKeyStore) async throws -> SyncOutcome {
        try device.compact()
        let engine = SyncEngine(store: store, keyStore: keyStore, isEnabled: { true }, deviceIdentifier: device.name)
        let outcome = await engine.sync(localModelData: try Data(contentsOf: device.modelURL))
        try device.apply(outcome)
        return outcome
    }

    func testRandomMultiDeviceHistoriesKeepTheCrossDevicePromises() async throws {
        let seed = PropertyEnv.seed(default: 0x5E7_D0C5)
        let iterations = PropertyEnv.iterations(default: 25)
        var rng = SeededRNG(seed: seed)

        for iteration in 0..<iterations {
            let caseSeed = rng.next()
            var caseRNG = SeededRNG(seed: caseSeed)
            let context = "seed 0x\(String(seed, radix: 16)) iteration \(iteration) case 0x\(String(caseSeed, radix: 16))"
            let store = InMemoryCloudStore()
            let keyStore = InMemoryKeyStore()
            let deviceCount = 2 + Int(caseRNG.next() % 2)
            let devices = try (0..<deviceCount).map { try Device(name: "dev\($0)-\(iteration)", directory: directory) }
            var everRemoved = Set<String>()
            var everReAdded = Set<String>()
            var trace: [String] = []

            for round in 0..<(2 + Int(caseRNG.next() % 4)) {
                // Mutations on every device.
                for device in devices {
                    for _ in 0..<(1 + Int(caseRNG.next() % 5)) {
                        let word = Self.alphabet[Int(caseRNG.next() % UInt64(Self.alphabet.count))]
                        let day = Int32(20_000 + Int(caseRNG.next() % 3))  // skewed clocks across devices
                        switch caseRNG.next() % 10 {
                        case 0..<5:
                            try device.commit(word, day: day); trace.append("\(device.name) commit \(word)@\(day)")
                        case 5..<6:
                            try device.tap(word, day: day); trace.append("\(device.name) tap \(word)")
                        case 6..<8:
                            try device.compact()
                            device.model.remove(word: word); try device.model.save(to: device.modelURL)
                            device.removed.insert(word); everRemoved.insert(word)
                            trace.append("\(device.name) remove \(word)")
                        case 8:
                            try device.compact()
                            try device.model.addUserWord(word); try device.model.save(to: device.modelURL)
                            everReAdded.insert(word)
                            trace.append("\(device.name) addUser \(word)")
                        default:
                            try device.compact(); trace.append("\(device.name) compact")
                        }
                    }
                }
                // Sync in random order, each device once …
                var order = Array(devices.indices)
                for i in order.indices.reversed() where i > 0 {
                    let j = Int(caseRNG.next() % UInt64(i + 1))
                    order.swapAt(i, j)
                }
                for index in order {
                    let outcome = try await sync(devices[index], store: store, keyStore: keyStore)
                    trace.append("\(devices[index].name) sync → \(label(outcome))")
                    if case .failed(let reason, _) = outcome {
                        XCTFail("\(context) round \(round): sync failed \(reason)\n\(trace.joined(separator: "\n"))")
                        return
                    }
                }
                // … then everyone once more with no mutations: must converge.
                for index in order {
                    let outcome = try await sync(devices[index], store: store, keyStore: keyStore)
                    trace.append("\(devices[index].name) sync2 → \(label(outcome))")
                }
                let payloads = try devices.map { try $0.payload() }
                for payload in payloads.dropFirst() where payload != payloads[0] {
                    XCTFail("\(context) round \(round): devices did not converge\n\(trace.joined(separator: "\n"))")
                    return
                }
                let converged = payloads[0]

                // Deletions stick (for words never explicitly re-added).
                for word in everRemoved.subtracting(everReAdded) {
                    for device in devices {
                        if device.model.isLearned(word) {
                            XCTFail("\(context) round \(round): deleted word \(word) resurrected on \(device.name)\n\(trace.joined(separator: "\n"))")
                            return
                        }
                    }
                    XCTAssertTrue(converged.tombstones.contains(word), "\(context): tombstone for \(word) lost")
                }
                // No inflation.
                for (word, stats) in converged.words {
                    let organic = devices.reduce(0) { $0 + ($1.organicCommits[word] ?? 0) }
                    if Int(stats.count) > organic {
                        XCTFail("\(context) round \(round): \(word) count \(stats.count) exceeds \(organic) organic commits\n\(trace.joined(separator: "\n"))")
                        return
                    }
                }
                // Idempotent one more time.
                for device in devices {
                    let outcome = try await sync(device, store: store, keyStore: keyStore)
                    XCTAssertEqual(outcome, .upToDate, "\(context) round \(round): \(device.name) not stable")
                }
            }
        }
    }

    private func label(_ outcome: SyncOutcome) -> String {
        switch outcome {
        case .disabled: return "disabled"
        case .upToDate: return "upToDate"
        case .pushed: return "pushed"
        case .pulled: return "pulled"
        case .merged: return "merged"
        case .failed(let r, _): return "failed(\(r))"
        }
    }

    // MARK: - Targeted cross-device scenarios

    func testClockSkewAcrossDevicesCountsAsDistinctDays() async throws {
        let store = InMemoryCloudStore()
        let keyStore = InMemoryKeyStore()
        let a = try Device(name: "a", directory: directory)
        let b = try Device(name: "b", directory: directory)
        try a.commit("hestur", day: 20_000)
        try b.commit("hestur", day: 20_001)  // B's clock is past UTC midnight
        _ = try await sync(a, store: store, keyStore: keyStore)
        _ = try await sync(b, store: store, keyStore: keyStore)
        _ = try await sync(a, store: store, keyStore: keyStore)
        XCTAssertTrue(a.model.isLearned("hestur"), "one commit per device on different UTC days ⇒ learned (documented)")
        XCTAssertTrue(b.model.isLearned("hestur"))
        XCTAssertEqual(a.model.commitCount(of: "hestur"), 1, "max, not sum")
    }

    func testDeleteOnOneDeviceBeatsTapOnAnotherInEitherOrder() async throws {
        for deleteFirst in [true, false] {
            let store = InMemoryCloudStore()
            let keyStore = InMemoryKeyStore()
            let a = try Device(name: "a-\(deleteFirst)", directory: directory)
            let b = try Device(name: "b-\(deleteFirst)", directory: directory)
            try b.tap("leyndarmál", day: 20_000)
            try b.compact()
            a.model.remove(word: "leyndarmál"); try a.model.save(to: a.modelURL)
            let order = deleteFirst ? [a, b] : [b, a]
            for device in order { _ = try await sync(device, store: store, keyStore: keyStore) }
            for device in order { _ = try await sync(device, store: store, keyStore: keyStore) }
            XCTAssertFalse(a.model.isLearned("leyndarmál"), "deleteFirst=\(deleteFirst)")
            XCTAssertFalse(b.model.isLearned("leyndarmál"), "deleteFirst=\(deleteFirst)")
            XCTAssertTrue(b.model.isTombstoned("leyndarmál"), "deleteFirst=\(deleteFirst)")
            XCTAssertEqual(b.model.commitCount(of: "leyndarmál"), 0, "deleteFirst=\(deleteFirst)")
        }
    }

    /// Device-local log markers must never cross devices: after a pull, each
    /// device still resumes its own log from its own marker (no re-apply).
    func testPullNeverDisturbsTheLocalLogFrontier() async throws {
        let store = InMemoryCloudStore()
        let keyStore = InMemoryKeyStore()
        let a = try Device(name: "a", directory: directory)
        let b = try Device(name: "b", directory: directory)
        try a.commit("heima", day: 20_000); try a.commit("heima", day: 20_001)
        try b.commit("vinnan", day: 20_000); try b.commit("vinnan", day: 20_001)
        _ = try await sync(a, store: store, keyStore: keyStore)
        _ = try await sync(b, store: store, keyStore: keyStore)
        // Run the engine directly (no helper compaction in between — note
        // that `compactAndSave` rotates the generation on EVERY run, even
        // with zero new events) so the frontier at sync time is known.
        try a.compact()
        let markerAtSync = a.model.consumedLogMarker
        let engine = SyncEngine(store: store, keyStore: keyStore, isEnabled: { true }, deviceIdentifier: "a")
        let outcome = await engine.sync(localModelData: try Data(contentsOf: a.modelURL))  // pulls B's word
        guard case .pulled = outcome else { return XCTFail("expected pulled, got \(outcome)") }
        try a.apply(outcome)
        XCTAssertTrue(a.model.isLearned("vinnan"))
        XCTAssertEqual(a.model.consumedLogMarker, markerAtSync, "pull must not touch the local frontier")
        // Local log still consumed exactly once.
        try a.compact()
        XCTAssertEqual(a.model.commitCount(of: "heima"), 2)
    }
}
