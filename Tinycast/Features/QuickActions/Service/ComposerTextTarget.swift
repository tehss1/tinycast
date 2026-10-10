import AppKit
@preconcurrency import ApplicationServices

@MainActor
final class ComposerTextTarget {
    enum PreparationFailure {
        case targetUnavailable
        case editorChanged
        case draftChanged
        case selectionRejected

        var message: String {
            switch self {
            case .targetUnavailable:
                "Composer lost the Outlook draft. Reopen Composer to try again. Draft copied."
            case .editorChanged:
                "Outlook moved focus away from the draft. Draft copied."
            case .draftChanged:
                "Outlook changed the draft while Composer was open. Reopen Composer. Draft copied."
            case .selectionRejected:
                "Outlook did not restore the insertion point. Draft copied."
            }
        }
    }

    let editor: AXUIElement
    let body: String
    let selectedRange: NSRange
    private(set) var replacementRange: NSRange?
    private(set) var preparationFailure: PreparationFailure?

    var anchor: ComposerDraftAnchor? {
        replacementRange.flatMap { ComposerDraftAnchor(body: body, range: $0) }
    }

    var draft: String? {
        guard let replacementRange, let range = Range(replacementRange, in: body) else { return nil }
        return String(body[range])
    }

    var hasFollowingLineBreak: Bool {
        guard let replacementRange, let range = Range(replacementRange, in: body),
            range.upperBound < body.endIndex
        else {
            return false
        }
        return body[range.upperBound].isNewline
    }

    init(editor: AXUIElement, body: String, selectedRange: NSRange) {
        self.editor = editor
        self.body = body
        self.selectedRange = selectedRange
        replacementRange = selectedRange
    }

    func restore(_ record: RewriteHistoryRecord, insertsAtCaret: Bool) {
        replacementRange = ComposerDraftAnchor.restoredRange(
            in: body, anchor: record.draftAnchor, selectedRange: selectedRange,
            insertsAtCaret: insertsAtCaret)
    }

    /// Activation precedes this check, so a different editor cannot receive the draft.
    func prepare(in app: NSRunningApplication?) -> Bool {
        preparationFailure = nil
        guard let app, let replacementRange else {
            preparationFailure = .targetUnavailable
            return false
        }
        guard let focused = AccessibilityText.focusedElement(in: app), CFEqual(focused, editor)
        else {
            preparationFailure = .editorChanged
            return false
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(editor, kAXValueAttribute as CFString, &value) == .success,
            value as? String == body
        else {
            preparationFailure = .draftChanged
            return false
        }
        var range = CFRange(location: replacementRange.location, length: replacementRange.length)
        guard let selected = AXValueCreate(.cfRange, &range),
            AXUIElementSetAttributeValue(
                editor, kAXSelectedTextRangeAttribute as CFString, selected) == .success,
            AXUIElementCopyAttributeValue(
                editor, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXValueGetTypeID()
        else {
            preparationFailure = .selectionRejected
            return false
        }
        // swiftlint:disable:next force_cast
        let observed = value as! AXValue
        guard AXValueGetType(observed) == .cfRange else {
            preparationFailure = .selectionRejected
            return false
        }
        var observedRange = CFRange()
        let accepted = AXValueGetValue(observed, .cfRange, &observedRange)
            && observedRange.location == range.location && observedRange.length == range.length
        if !accepted { preparationFailure = .selectionRejected }
        return accepted
    }
}
