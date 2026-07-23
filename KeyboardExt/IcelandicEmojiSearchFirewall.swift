import KeyboardKit

/// Pure decision seam for the action-handler firewall. Tests exercise real
/// KeyboardKit gestures/actions without needing a live UITextDocumentProxy.
enum IcelandicEmojiSearchFirewall {
    enum Command: Equatable {
        case append(String)
        case backspace
        case done
        case exitAndPass
        case pass
    }

    static func command(
        isActive: Bool,
        gesture: Keyboard.Gesture,
        action: KeyboardAction
    ) -> Command {
        guard isActive else { return .pass }
        switch (gesture, action) {
        case (.release, .character(let text)): return .append(text)
        case (.release, .space): return .append(" ")
        case (.press, .backspace), (.repeatPress, .backspace): return .backspace
        case (.release, .primary(.done)): return .done
        case (.press, .keyboardType(.alphabetic)): return .exitAndPass
        default: return .pass
        }
    }
}
