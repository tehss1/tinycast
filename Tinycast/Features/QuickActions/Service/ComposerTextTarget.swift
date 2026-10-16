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
    private var narrowedSelection: (original: NSRange, range: NSRange, text: String)?

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
        replacementRange = ComposerDraftAnchor.replacementRange(in: body, selectedRange: selectedRange)
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
    /// `excludingSelectionEdges` is for Outlook, which drops a pasted trailing line break: the
    /// selection's edge whitespace is deselected instead, so it stays in the draft.
    /// Delivery prepares the target more than once, so a later check expects the narrowed selection.
    func prepare(in app: NSRunningApplication?, excludingSelectionEdges: Bool = false) -> Bool {
        preparationFailure = nil
        if case .focusedField(let selection) = scope {
            guard prepareField(
                in: app, selection: narrowedSelection?.range ?? selection,
                text: narrowedSelection?.text ?? selectionText)
            else { return false }
            if excludingSelectionEdges, narrowedSelection == nil, let app,
                let focused = AccessibilityText.focusedElement(in: app)
            {
                deselectEdges(in: focused)
            }
            return true
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

    /// Best effort: a field that refuses the narrower range keeps the selection as it was.
    private func deselectEdges(in field: AXUIElement) {
        guard let selectionText, let selected = AccessibilityText.selectedRange(of: field),
            let inner = QuickActionOutput.innerRange(of: selectionText, at: selected)
        else { return }
        let text = (selectionText as NSString).substring(
            with: NSRange(location: inner.location - selected.location, length: inner.length))
        if Self.select(inner, in: field) {
            narrowedSelection = (original: selected, range: inner, text: text)
        } else {
            _ = Self.select(selected, in: field)
        }
    }

    /// After a failed delivery, the reader gets back the selection they made, if nothing landed.
    func restoreSelection(in app: NSRunningApplication?) {
        guard let narrowed = narrowedSelection else { return }
        narrowedSelection = nil
        guard let app, let focused = AccessibilityText.focusedElement(in: app),
            CFEqual(focused, editor),
            AccessibilityText.selectedRange(of: focused) == narrowed.range,
            AccessibilityText.selectedText(of: focused) == narrowed.text
        else { return }
        _ = Self.select(narrowed.original, in: focused)
    }

    private static func select(_ range: NSRange, in field: AXUIElement) -> Bool {
        var wanted = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &wanted),
            AXUIElementSetAttributeValue(
                field, kAXSelectedTextRangeAttribute as CFString, value) == .success
        else { return false }
        return AccessibilityText.selectedRange(of: field) == range
    }

    private func prepareField(
        in app: NSRunningApplication?, selection: NSRange?, text selectionText: String?
    ) -> Bool {
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
