// Minimal stand-in for the iOS-only vendored ISEmojiView package
// (Packages/ISEmojiView), exposing exactly the three model types that
// KeyboardExt/EmojiCatalog.swift references, so that file compiles unchanged
// in the headless macOS launch probe. No UI, no behaviour.

import Foundation

public enum Category: Equatable {
    case recents
    case smileysAndPeople
    case animalsAndNature
    case foodAndDrink
    case activity
    case travelAndPlaces
    case objects
    case symbols
    case flags
    case custom(String, String)
}

public class Emoji {
    public var emojis: [String]!
    public init(emojis: [String]) { self.emojis = emojis }
}

public class EmojiCategory {
    public var category: Category!
    public var emojis: [Emoji]!
    public init(category: Category, emojis: [Emoji]) {
        self.category = category
        self.emojis = emojis
    }
}
