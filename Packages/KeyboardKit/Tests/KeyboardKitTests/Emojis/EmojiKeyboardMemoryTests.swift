//
//  EmojiKeyboardMemoryTests.swift
//  KeyboardKit
//
//  Memory regression guard for the vendored emoji keyboard's data +
//  rendering layer (PLAN.md: "Emoji: keep KeyboardKit's stock emoji picker …
//  Add a memory regression test around KK GH #757 (font-cache bloat)").
//
//  Background — KeyboardKit GH #757: the emoji keyboard can balloon process
//  memory. Two compounding causes, both unresolved upstream in any version:
//   1. SwiftUI's `LazyVGrid` allocates emoji cells but never deallocates
//      them (called out verbatim in `Emoji.KeyboardStyle`'s own doc comment),
//      so scrolling the full picker keeps every visited cell alive.
//   2. Rendering each emoji glyph — `Text(emoji.char).font(...)`, i.e. the
//      CoreText/`String(char).size`/draw path — populates a per-glyph font
//      cache that grows with the number of distinct emoji rendered.
//  Emoji is not v1-critical, but it sits under the extension's jetsam budget,
//  so a runaway regression here (a KeyboardKit bump, an emoji-set expansion,
//  a caching change) must fail CI rather than ship.
//
//  What this test exercises: the *data + glyph* layers the picker drives —
//  `Emoji.all`, every standard `EmojiCategory`, `parseEmojis` /
//  `isAvailableInCurrentRuntime`, the search path (`Emoji.all.matching`),
//  and the `NSString.size(withAttributes:)` / draw glyph path at the emoji
//  keyboard's real item font size — iterated across all categories several
//  times, then asserts `phys_footprint` growth (measured with mach
//  `task_info`, the same instrument as `Packages/LemmaCore`'s lemma-bench and
//  the metric iOS jetsam enforces) stays under a generous ceiling.
//
//  What it does NOT cover: the SwiftUI `LazyVGrid` cell-retention half of
//  #757 (cause 1) — that needs a live `EmojiKeyboard` view host + scrolling,
//  which can't run in this headless XCTest bundle. That is left to the
//  on-device memory QA in PLAN.md's testing pyramid. This test targets the
//  glyph/font-cache half (cause 2) plus the data layer, which run headlessly.
//
//  Ceiling rationale: +80 MB is deliberately generous — this is a
//  runaway-regression tripwire, not a precise budget. It's measured as growth
//  from a WARMED baseline (after `Emoji.all` and every category's lazy static
//  parse have run once), so one-time lazy allocations aren't counted; only
//  per-render growth is. Tighten with real device figures once M0/M2 device
//  memory data lands (PLAN.md).
//

#if os(iOS)
import KeyboardKit
import UIKit
import XCTest

final class EmojiKeyboardMemoryTests: XCTestCase {

    /// mach `task_info` sample (mirrors `LemmaCore/Sources/lemma-bench`).
    /// `phys_footprint` is the field the iOS jetsam limit is enforced on.
    private struct MemorySample {
        let physFootprintBytes: UInt64

        static func current() -> MemorySample {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
            )
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            guard kr == KERN_SUCCESS else { return MemorySample(physFootprintBytes: 0) }
            return MemorySample(physFootprintBytes: UInt64(info.phys_footprint))
        }
    }

    /// Generous runaway-regression ceiling (see file header). Growth above
    /// this from a warmed baseline means something started leaking per-render
    /// (the GH #757 failure mode), not merely that emoji data is large.
    private let ceilingBytes: UInt64 = 80 * 1024 * 1024

    /// Emoji keyboard's real item font size — `Emoji.KeyboardStyle`'s default
    /// `itemFont` is `.system(size: 33)`, so glyphs are cached at that size on
    /// the actual keyboard.
    private let itemFont = UIFont.systemFont(ofSize: 33)

    func testEmojiDataAndGlyphRenderingStaysUnderMemoryCeiling() {
        // Warm up the lazy static caches so the baseline excludes one-time
        // parse/allocation (`Emoji.all`, each category's `emojisFor…` static,
        // and the runtime-availability dictionary).
        _ = Emoji.all.count
        let categories = EmojiCategory.standardCategories
        for category in categories { _ = category.emojis.count }
        exerciseAllCategories(categories, renderIterationsPerEmoji: 1)

        let baseline = MemorySample.current()

        // Drive the data + glyph paths the picker uses, across every category,
        // several times. This is where a per-render font-cache regression
        // would compound.
        for _ in 0..<3 {
            exerciseAllCategories(categories, renderIterationsPerEmoji: 1)
        }
        // The search path also enumerates + name-matches all emojis.
        for query in ["grin", "cat", "heart", "flag"] {
            _ = Emoji.all.matching(query).count
        }

        let after = MemorySample.current()
        let growth = after.physFootprintBytes >= baseline.physFootprintBytes
            ? after.physFootprintBytes - baseline.physFootprintBytes
            : 0

        XCTAssertLessThan(
            growth, ceilingBytes,
            """
            Emoji keyboard data/glyph rendering grew phys_footprint by \
            \(mb(growth)) from a warmed baseline, over the \(mb(ceilingBytes)) \
            runaway-regression ceiling (KeyboardKit GH #757). Baseline \
            \(mb(baseline.physFootprintBytes)), after \(mb(after.physFootprintBytes)).
            """
        )
    }

    /// Sanity: the picker actually has a substantial emoji set to render, so
    /// the memory assertion above is exercising a real workload (a regression
    /// that emptied the categories would otherwise pass vacuously).
    func testStandardCategoriesExposeEmojis() {
        let total = EmojiCategory.standardCategories.reduce(0) { $0 + $1.emojis.count }
        XCTAssertGreaterThan(total, 500, "expected the stock emoji set to be non-trivial; got \(total)")
    }

    // MARK: - Helpers

    /// Touch every emoji in every category the way the picker's data +
    /// rendering layers do: availability check, char string, glyph
    /// measurement, and a small rasterizing draw (the `String(char)` font
    /// path GH #757 implicates).
    private func exerciseAllCategories(
        _ categories: [EmojiCategory],
        renderIterationsPerEmoji: Int
    ) {
        let attributes: [NSAttributedString.Key: Any] = [.font: itemFont]
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40))
        for category in categories {
            for emoji in category.emojis {
                guard emoji.isAvailableInCurrentRuntime else { continue }
                // Each emoji's transient render products (the rasterized
                // CGImage) are drained per iteration by an autorelease pool,
                // so what remains at measurement time is the PERSISTENT
                // per-glyph font cache growth (the GH #757 failure mode) —
                // not one-shot image-buffer churn, which would dwarf and mask
                // a real regression and make the tripwire flap.
                autoreleasepool {
                    let char = emoji.char as NSString
                    for _ in 0..<renderIterationsPerEmoji {
                        // Glyph measurement — populates the CoreText
                        // font/glyph cache exactly as laying out the cell does.
                        _ = char.size(withAttributes: attributes)
                    }
                    // A rasterizing draw forces actual glyph drawing (the
                    // heavier half of the font-cache path).
                    _ = renderer.image { _ in
                        char.draw(at: .zero, withAttributes: attributes)
                    }
                }
            }
        }
    }

    private func mb(_ bytes: UInt64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }
}
#endif
