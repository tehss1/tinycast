import AppKit
@preconcurrency import ApplicationServices

@MainActor
final class ComposerTextTarget {
    let editor: AXUIElement
    let body: String
    let selectedRange: NSRange
    private(set) var replacementRange: NSRange?

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

    func restore(_ record: RewriteHistoryRecord) {
        if let range = record.draftAnchor?.rangePreservingTrailingLineBreaks(in: body) {
            replacementRange = range
        } else if selectedRange.length > 0 {
            replacementRange = selectedRange
        } else {
            replacementRange = nil
        }
    }

    /// Activation precedes this check, so a different editor cannot receive the draft.
    func prepare(in app: NSRunningApplication?) -> Bool {
        guard let app, let replacementRange,
            let focused = AccessibilityText.focusedElement(in: app), CFEqual(focused, editor)
        else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(editor, kAXValueAttribute as CFString, &value) == .success,
            value as? String == body
        else { return false }
        var range = CFRange(location: replacementRange.location, length: replacementRange.length)
        guard let selected = AXValueCreate(.cfRange, &range),
            AXUIElementSetAttributeValue(
                editor, kAXSelectedTextRangeAttribute as CFString, selected) == .success,
            AXUIElementCopyAttributeValue(
                editor, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return false }
        // swiftlint:disable:next force_cast
        let observed = value as! AXValue
        guard AXValueGetType(observed) == .cfRange else { return false }
        var observedRange = CFRange()
        return AXValueGetValue(observed, .cfRange, &observedRange)
            && observedRange.location == range.location && observedRange.length == range.length
    }
}
