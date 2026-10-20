import Foundation

/// One case per cause: a single "nothing selected" tells a reader to select what they selected.
enum QuickActionFailure: LocalizedError, Equatable {
    case needsAccessibility
    case noTarget
    /// The app answered but exposes no focused text element — Chromium before its tree is built.
    case unreadableApp(String?)
    case noSelection
    case tooLong
    /// Whether the budget came from the selection, so selecting less would raise the odds.
    case replyTooLong(selectionSized: Bool)

    var errorDescription: String? {
        switch self {
        case .needsAccessibility:
<<<<<<< HEAD
            return "Tinycast needs Accessibility permission to read text in other apps."
        case .noTarget:
            return "Focus a text field in another app first."
        case .unreadableApp(let name):
            return "\(name) doesn't share its text with Tinycast."
=======
            return String(localized: "Tinycast needs the Accessibility permission to read the selected text.")
        case .noTarget:
            return String(localized: "Select text in another app first.")
        case .unreadableApp(let name?):
            return String(localized: "\(name) doesn't share its text with Tinycast.")
        case .unreadableApp(nil):
            return String(localized: "That app doesn't share its text with Tinycast.")
>>>>>>> refs/upstream/v0.12.1
        case .noSelection:
            return String(localized: "Select some text first.")
        case .tooLong:
<<<<<<< HEAD
            return "That selection is too long to work on."
        case .replyTooLong(let selectionSized):
            return "The reply hit the model's length limit, so nothing was replaced. "
                + (selectionSized ? "Select less text and try again." : "Ask for a shorter reply.")
=======
            return String(localized: "That selection is too long to work on.")
>>>>>>> refs/upstream/v0.12.1
        }
    }

    /// The only failure with somewhere to send the reader, and so the only one worth a dialog.
    var opensAccessibilitySettings: Bool { self == .needsAccessibility }
}
