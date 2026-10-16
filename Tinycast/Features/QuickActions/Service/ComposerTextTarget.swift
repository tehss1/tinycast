import AppKit
@preconcurrency import ApplicationServices

/// The text field a Quick Action was invoked from, checked again before anything is delivered.
@MainActor
final class ComposerTextTarget {
    private static let deliveryTimeout: Float = 1

    enum Scope {
        case outlookDraft
        case focusedField(selection: NSRange?)
    }

    enum PreparationFailure {
        case targetUnavailable
        case editorChanged
        case draftChanged
        case selectionRejected
        case fieldChanged
        case selectionChanged

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
            case .fieldChanged:
                "Focus moved away from the original text field. Result copied."
            case .selectionChanged:
                "The selection changed before the result arrived. Result copied."
            }
        }
    }

    let editor: AXUIElement
    let body: String
    let selectedRange: NSRange
    let scope: Scope
    private let selectionText: String?
    let characterCount: Int?
    private(set) var replacementRange: NSRange?
    private(set) var preparationFailure: PreparationFailure?

    var anchor: ComposerDraftAnchor? {
        replacementRange.flatMap { ComposerDraftAnchor(body: body, range: $0) }
    }

    var draft: String? {
        guard let replacementRange, let range = Range(replacementRange, in: body) else { return nil }
        return String(body[range])
    }

    var textBoundaries: ComposerDraftAnchor.TextBoundaries? {
        guard case .outlookDraft = scope, let replacementRange else { return nil }
        return ComposerDraftAnchor.TextBoundaries(body: body, range: replacementRange)
    }

    init(editor: AXUIElement, body: String, selectedRange: NSRange) {
        self.editor = editor
        self.body = body
        self.selectedRange = selectedRange
        scope = .outlookDraft
        selectionText = nil
        characterCount = body.utf16.count
        replacementRange = selectedRange
    }

    private init(field: AXUIElement, selection: NSRange?) {
        editor = field
        body = ""
        selectedRange = selection ?? NSRange(location: NSNotFound, length: 0)
        scope = .focusedField(selection: selection)
        selectionText = AccessibilityText.selectedText(of: field)
        characterCount = Self.characterCount(of: field)
    }

    /// A count, never the value: outside Outlook the field's text itself is not read.
    private static func characterCount(of field: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            field, kAXNumberOfCharactersAttribute as CFString, &value) == .success
        else { return nil }
        return (value as? NSNumber)?.intValue
    }

    static func focusedField(in app: NSRunningApplication?) -> ComposerTextTarget? {
        guard let app, let field = AccessibilityText.focusedElement(in: app) else { return nil }
        return ComposerTextTarget(field: field, selection: AccessibilityText.selectedRange(of: field))
    }

    func isFocused(in app: NSRunningApplication) -> Bool {
        guard let focused = AccessibilityText.focusedElement(in: app) else { return false }
        return CFEqual(focused, editor)
    }

    func restore(_ record: RewriteHistoryRecord, insertsAtCaret: Bool) {
        replacementRange = ComposerDraftAnchor.restoredRange(
            in: body, anchor: record.draftAnchor, selectedRange: selectedRange,
            insertsAtCaret: insertsAtCaret)
    }

    /// Activation precedes this check, so a different editor cannot receive the draft.
    func prepare(in app: NSRunningApplication?) -> Bool {
        preparationFailure = nil
        if case .focusedField(let selection) = scope {
            return prepareField(in: app, selection: selection)
        }
        guard let app, let replacementRange else {
            preparationFailure = .targetUnavailable
            return false
        }
        guard AXUIElementSetMessagingTimeout(editor, Self.deliveryTimeout) == .success else {
            preparationFailure = .targetUnavailable
            return false
        }
        guard isFocused(in: app) else {
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

    private func prepareField(in app: NSRunningApplication?, selection: NSRange?) -> Bool {
        guard let app, let focused = AccessibilityText.focusedElement(in: app) else {
            preparationFailure = .fieldChanged
            return false
        }
        var originalProcess: pid_t = 0
        var focusedProcess: pid_t = 0
        guard AXUIElementGetPid(editor, &originalProcess) == .success,
            AXUIElementGetPid(focused, &focusedProcess) == .success,
            originalProcess == app.processIdentifier, focusedProcess == originalProcess
        else {
            preparationFailure = .fieldChanged
            return false
        }
        let sameElement = CFEqual(focused, editor)
        if sameElement, let selection, AccessibilityText.selectedRange(of: focused) != selection {
            preparationFailure = .selectionChanged
            return false
        }
        if !sameElement, selection?.length == 0 {
            preparationFailure = .fieldChanged
            return false
        }
        if let selectionText {
            guard AccessibilityText.selectedText(of: focused) == selectionText else {
                preparationFailure = .selectionChanged
                return false
            }
            return true
        }
        guard sameElement else {
            preparationFailure = .fieldChanged
            return false
        }
        return true
    }
}
