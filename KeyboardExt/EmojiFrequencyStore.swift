//
//  EmojiFrequencyStore.swift
//  LyklabordKeyboard
//
//  On-device "frecency" for emoji: frequency blended with exponential
//  time-decay, so the long-press quick-row on the emoji key reflects what the
//  user reaches for LATELY — not just all-time counts, and not a plain LRU
//  recents list. Backed by the App Group's shared UserDefaults; it never
//  leaves the device (no iCloud, no server — same privacy stance as the rest
//  of the keyboard's state).
//
//  Algorithm — lazy decay, no background sweep:
//    Each emoji stores (score, lastTouch). A score is only meaningful "as of"
//    its lastTouch, so before using it we decay it to now:
//        decayed = score * 2^(-(now - lastTouch) / halfLife)
//    On use: decay the old score to now, then +1. On read: decay every entry
//    to now and sort. With a 30-day half-life, an emoji used once a month
//    holds roughly steady; a burst of use rockets it up and then fades if it
//    stops. Comparisons are always self-consistent because everything is
//    decayed to the same "now".
//
//  Threading: touched only from the keyboard's main-thread action handler and
//  the (main-thread) callout builder, so no locking is needed.
//

import Foundation

final class EmojiFrequencyStore {

    static let shared = EmojiFrequencyStore(
        defaults: UserDefaults(suiteName: "group.is.solberg.lyklabord") ?? .standard
    )

    private let defaults: UserDefaults
    private let key = "emojiFrecency.v1"
    private let halfLife: Double = 30 * 86_400   // 30 days, in seconds
    private let maxEntries = 60                   // bound the persisted set

    /// Popular defaults (global + Europe/Iceland-weighted, incl. 🇮🇸) used to
    /// fill the quick-row before the user has enough personal history. Ordered
    /// by descending popularity; personal emojis always outrank these once
    /// they exist.
    static let seed: [String] = [
        "😂", "❤️", "🤣", "😭", "🥰", "😍", "😊", "🙏", "👍", "🔥",
        "✨", "🎉", "🥺", "😅", "💀", "👀", "🙌", "😘", "😎", "🇮🇸"
    ]

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    // MARK: - Persistence (JSON Data — avoids plist NSNumber bridging surprises)

    private func load() -> [String: [Double]] {
        guard
            let data = defaults.data(forKey: key),
            let dict = try? JSONDecoder().decode([String: [Double]].self, from: data)
        else { return [:] }
        return dict
    }

    private func save(_ dict: [String: [Double]]) {
        if let data = try? JSONEncoder().encode(dict) {
            defaults.set(data, forKey: key)
        }
    }

    private func decayFactor(from lastTouch: Double, to now: Double) -> Double {
        let dt = max(0, now - lastTouch)
        return pow(2.0, -dt / halfLife)
    }

    private func decayedScore(_ entry: [Double], now: Double) -> Double {
        guard entry.count == 2 else { return 0 }
        return entry[0] * decayFactor(from: entry[1], to: now)
    }

    // MARK: - API

    /// Record one use of `emoji`: decay its prior score to now, then +1.
    func record(_ emoji: String) {
        guard !emoji.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        var dict = load()
        dict[emoji] = [decayedScore(dict[emoji] ?? [], now: now) + 1.0, now]

        // Keep only the strongest `maxEntries` so storage stays tiny.
        if dict.count > maxEntries {
            let ranked = dict.sorted { decayedScore($0.value, now: now) > decayedScore($1.value, now: now) }
            dict = Dictionary(uniqueKeysWithValues: ranked.prefix(maxEntries).map { ($0.key, $0.value) })
        }
        save(dict)
    }

    /// The user's top emojis by decayed score, padded with popular seed emojis
    /// (never duplicated) so the result always has `count` entries.
    func top(_ count: Int) -> [String] {
        guard count > 0 else { return [] }
        let now = Date().timeIntervalSince1970
        let personal = load()
            .filter { $0.value.count == 2 }
            .sorted { decayedScore($0.value, now: now) > decayedScore($1.value, now: now) }
            .map { $0.key }

        var result = personal
        if result.count < count {
            for emoji in Self.seed where !result.contains(emoji) {
                result.append(emoji)
                if result.count == count { break }
            }
        }
        return Array(result.prefix(count))
    }
}
