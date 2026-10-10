import AppKit
@preconcurrency import ApplicationServices

@MainActor
enum OutlookComposeContextReader {
    private static let outlookBundleIdentifier = "com.microsoft.Outlook"
    private static let timeout: Float = 1
    private static let maximumElements = 800
    /// A wedged Outlook answers each call only at its timeout, so the whole read is capped too.
    private static let budget: Duration = .seconds(2)
    private static let subjectFieldIdentifier = "subjectTextField"
    private static let recipientFieldIdentifiers = Set([
        "toTextField", "ccTextField", "bccTextField"
    ])

    static func isOutlook(_ app: NSRunningApplication?) -> Bool {
        app?.bundleIdentifier == outlookBundleIdentifier
    }

    struct Capture {
        let context: QuickActionContext?
        let target: ComposerTextTarget
    }

    static func read(in app: NSRunningApplication?) -> Capture? {
        guard let app, isOutlook(app),
            let editor = AccessibilityText.focusedElement(in: app),
            let body = string(editor, attribute: kAXValueAttribute),
            let selectedRange = selectedRange(in: editor), Range(selectedRange, in: body) != nil
        else { return nil }

        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, timeout)
        let window =
            element(application, attribute: kAXFocusedWindowAttribute)
            ?? element(application, attribute: kAXMainWindowAttribute)
        let deadline = ContinuousClock.now + budget
        let fields = window.map {
            descendants(
                identifiers: recipientFieldIdentifiers.union([subjectFieldIdentifier]), in: $0,
                until: deadline)
        } ?? []
        let recipientFields = fields.filter { $0.identifier != subjectFieldIdentifier }
        let subjectField = fields.first { $0.identifier == subjectFieldIdentifier }

        let documentIdentity = "\(app.processIdentifier):\(app.launchDate?.timeIntervalSince1970 ?? 0):"
            + "\(CFHash(editor))"
        let context = QuickActionContext.outlook(
            body: body,
            selectedRange: selectedRange,
            recipient: QuickActionContext.outlookRecipients(
                from: recipientFields.flatMap { textCandidates(in: $0.element, until: deadline) }),
            subject: subjectField.flatMap { subject(in: $0.element, until: deadline) },
            documentIdentity: documentIdentity)
        return Capture(
            context: context,
            target: ComposerTextTarget(editor: editor, body: body, selectedRange: selectedRange))
    }

    private static func descendants(
        identifiers: Set<String>, in root: AXUIElement, until deadline: ContinuousClock.Instant
    ) -> [(identifier: String, element: AXUIElement)] {
        var queue = [root]
        var index = 0
        var matches: [(identifier: String, element: AXUIElement)] = []
        while index < queue.count, index < maximumElements, ContinuousClock.now < deadline {
            let candidate = queue[index]
            index += 1
            if let identifier = string(candidate, attribute: kAXIdentifierAttribute),
                identifiers.contains(identifier)
            {
                matches.append((identifier, candidate))
            }
            queue.append(contentsOf: children(of: candidate))
        }
        return matches
    }

    /// The field's own value first: by length alone, its label would beat a short subject.
    private static func subject(in field: AXUIElement, until deadline: ContinuousClock.Instant) -> String? {
        if let value = string(field, attribute: kAXValueAttribute), usable(value) { return value }
        return textCandidates(in: field, until: deadline).max { $0.count < $1.count }
    }

    private static func textCandidates(
        in root: AXUIElement, until deadline: ContinuousClock.Instant
    ) -> [String] {
        var queue = [root]
        var index = 0
        var candidates: [String] = []
        while index < queue.count, index < maximumElements, ContinuousClock.now < deadline {
            let candidate = queue[index]
            index += 1
            for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                if let text = string(candidate, attribute: attribute), usable(text) {
                    candidates.append(text)
                }
            }
            queue.append(contentsOf: children(of: candidate))
        }
        return candidates
    }

    private static func usable(_ value: String) -> Bool {
        !value.replacingOccurrences(of: "\u{fffc}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXChildrenAttribute as CFString, &value) == .success,
            let children = value as? [AXUIElement]
        else { return [] }
        for child in children { AXUIElementSetMessagingTimeout(child, timeout) }
        return children
    }

    private static func element(_ root: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(root, attribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        // swiftlint:disable:next force_cast
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    private static func string(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func selectedRange(in element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        // swiftlint:disable:next force_cast
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
}
