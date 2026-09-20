import AppKit
@preconcurrency import ApplicationServices

@MainActor
enum OutlookComposeContextReader {
    private static let outlookBundleIdentifier = "com.microsoft.Outlook"
    private static let timeout: Float = 1
    private static let maximumElements = 800
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
        let recipientFields = window.map {
            descendants(identifiers: recipientFieldIdentifiers, in: $0)
        } ?? []
        let subjectField = window.flatMap { descendant(identifier: "subjectTextField", in: $0) }

        let documentIdentity = "\(app.processIdentifier):\(app.launchDate?.timeIntervalSince1970 ?? 0):"
            + "\(CFHash(editor))"
        let context = QuickActionContext.outlook(
            body: body,
            selectedRange: selectedRange,
            recipient: recipientText(in: recipientFields),
            subject: subjectField.flatMap(bestText), documentIdentity: documentIdentity)
        return Capture(
            context: context,
            target: ComposerTextTarget(editor: editor, body: body, selectedRange: selectedRange))
    }

    private static func descendant(identifier: String, in root: AXUIElement) -> AXUIElement? {
        var queue = [root]
        var index = 0
        while index < queue.count, index < maximumElements {
            let candidate = queue[index]
            index += 1
            if string(candidate, attribute: kAXIdentifierAttribute) == identifier {
                return candidate
            }
            queue.append(contentsOf: children(of: candidate))
        }
        return nil
    }

    private static func descendants(
        identifiers: Set<String>, in root: AXUIElement
    ) -> [AXUIElement] {
        var queue = [root]
        var index = 0
        var matches: [AXUIElement] = []
        while index < queue.count, index < maximumElements {
            let candidate = queue[index]
            index += 1
            if let identifier = string(candidate, attribute: kAXIdentifierAttribute),
                identifiers.contains(identifier)
            {
                matches.append(candidate)
            }
            queue.append(contentsOf: children(of: candidate))
        }
        return matches
    }

    private static func bestText(in root: AXUIElement) -> String? {
        textCandidates(in: root).max(by: { $0.count < $1.count })
    }

    private static func recipientText(in fields: [AXUIElement]) -> String? {
        QuickActionContext.outlookRecipients(from: fields.flatMap(textCandidates))
    }

    private static func textCandidates(in root: AXUIElement) -> [String] {
        var queue = [root]
        var index = 0
        var candidates: [String] = []
        while index < queue.count, index < maximumElements {
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
