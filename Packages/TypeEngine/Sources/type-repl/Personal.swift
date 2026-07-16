import Foundation
import TypeEngine

/// In-memory personal vocabulary for scenario seeding (`PERSONAL`,
/// `PERSONAL_BIGRAM`, `TOMBSTONE` directives) — the harness twin of the
/// extension's `PersonalSnapshot(model:)`.
struct SeededPersonalVocabulary: PersonalVocabulary {
    var words: [String: UInt32] = [:]
    var bigrams: [String: UInt32] = [:]  // "first second" (single space)
    var tombstones: Set<String> = []
    /// Deliberately learned words (`PERSONAL_EXPLICIT` — the dictionary
    /// editor / verbatim-tap / import class); everything seeded via plain
    /// `PERSONAL` is implicit, like organically threshold-learned commits.
    var explicit: Set<String> = []

    var isEmpty: Bool { words.isEmpty && bigrams.isEmpty && tombstones.isEmpty }

    func allWords() -> [(word: String, count: UInt32)] {
        words
            .filter { !tombstones.contains($0.key) }
            .map { (word: $0.key, count: $0.value) }
    }

    func continuations(of first: String, limit: Int) -> [(word: String, count: UInt32)] {
        guard limit > 0 else { return [] }
        let prefix = first + " "
        return bigrams
            .compactMap { key, count -> (word: String, count: UInt32)? in
                guard key.hasPrefix(prefix) else { return nil }
                let follower = String(key.dropFirst(prefix.count))
                guard !tombstones.contains(follower) else { return nil }
                return (word: follower, count: count)
            }
            .sorted { $0.count > $1.count || ($0.count == $1.count && $0.word < $1.word) }
            .prefix(limit)
            .map { $0 }
    }

    func bigramCount(_ first: String, _ second: String) -> UInt32? {
        bigrams["\(first) \(second)"]
    }

    func isTombstoned(_ word: String) -> Bool {
        tombstones.contains(word)
    }

    func isExplicit(_ word: String) -> Bool {
        explicit.contains(word)
    }
}
