import AppKit
@preconcurrency import ApplicationServices

@MainActor
enum OutlookComposeContextReader {
    private static let outlookBundleIdentifier = "com.microsoft.Outlook"
    private static let maximumElements = 800
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
        guard let app, isOutlook(app) else { return nil }
        let started = ContinuousClock.now
        var access = Access(deadline: started + QuickActionContext.OutlookCaptureBudget.total)
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard let editor = access.element(application, attribute: kAXFocusedUIElementAttribute),
            let body = access.string(editor, attribute: kAXValueAttribute),
            let selectedRange = access.selectedRange(in: editor), Range(selectedRange, in: body) != nil
        else { return nil }

        let window = access.element(application, attribute: kAXFocusedWindowAttribute)
            ?? access.element(application, attribute: kAXMainWindowAttribute)
        let fields: [(identifier: String, element: AXUIElement)]
        if let window {
            fields = access.descendants(
                identifiers: recipientFieldIdentifiers.union([subjectFieldIdentifier]), in: window,
                allowance: QuickActionContext.OutlookCaptureBudget.discoveryAllowance(
                    elapsed: ContinuousClock.now - started))
        } else {
            fields = []
        }
        let subject: String?
        if let field = fields.first(where: { $0.identifier == subjectFieldIdentifier }) {
            subject = access.subject(in: field.element)
        } else {
            subject = nil
        }
        let recipientFields = fields.filter { $0.identifier != subjectFieldIdentifier }
        var candidates: [String] = []
        for field in recipientFields { candidates.append(contentsOf: access.textCandidates(in: field.element)) }
        let recipient = QuickActionContext.outlookRecipients(
            from: candidates, captureComplete: !recipientFields.isEmpty && access.complete)

        let documentIdentity = "\(app.processIdentifier):\(app.launchDate?.timeIntervalSince1970 ?? 0):"
            + "\(CFHash(editor))"
        let context = QuickActionContext.outlook(
            body: body, selectedRange: selectedRange, recipient: recipient, subject: subject,
            documentIdentity: documentIdentity)
        return Capture(
            context: context,
            target: ComposerTextTarget(editor: editor, body: body, selectedRange: selectedRange))
    }

    @MainActor
    private struct Access {
        var deadline: ContinuousClock.Instant
        var complete = true

        mutating func descendants(
            identifiers: Set<String>, in root: AXUIElement, allowance: Duration
        ) -> [(identifier: String, element: AXUIElement)] {
            let readingDeadline = deadline
            deadline = min(deadline, ContinuousClock.now + allowance)
            defer { deadline = readingDeadline }
            var queue = [root]
            var index = 0
            var matches: [(identifier: String, element: AXUIElement)] = []
            var found: Set<String> = []
            while index < queue.count,
                QuickActionContext.OutlookCaptureBudget.shouldDiscover(found: found, wanted: identifiers),
                withinDeadline()
            {
                let candidate = queue[index]
                index += 1
                if let identifier = string(candidate, attribute: kAXIdentifierAttribute),
                    identifiers.contains(identifier)
                {
                    matches.append((identifier, candidate))
                    found.insert(identifier)
                    continue
                }
                _ = appendChildren(of: candidate, to: &queue)
            }
            return matches
        }

        mutating func subject(in field: AXUIElement) -> String? {
            if let value = string(field, attribute: kAXValueAttribute), usable(value) { return value }
            return textCandidates(in: field).max { $0.count < $1.count }
        }

        mutating func textCandidates(in root: AXUIElement) -> [String] {
            var queue = [root]
            var index = 0
            var candidates: [String] = []
            while index < queue.count, withinDeadline() {
                let candidate = queue[index]
                index += 1
                var readable = false
                var texts: [String] = []
                var fieldValue: String?
                for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                    if let text = string(candidate, attribute: attribute) {
                        readable = true
                        if usable(text) {
                            texts.append(text)
                            if attribute == kAXValueAttribute { fieldValue = text }
                        }
                    }
                }
                let childCount = appendChildren(of: candidate, to: &queue)
                let addresses = texts.filter { !EmailAddressPattern.matches(in: $0).isEmpty }
                if !addresses.isEmpty {
                    candidates.append(contentsOf: addresses)
                } else if childCount == 0 {
                    candidates.append(contentsOf: texts)
                    if !readable { complete = false }
                } else if let fieldValue {
                    candidates.append(fieldValue)
                }
            }
            return candidates
        }

        private func usable(_ value: String) -> Bool {
            !value.replacingOccurrences(of: "\u{fffc}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        private mutating func appendChildren(of element: AXUIElement, to queue: inout [AXUIElement]) -> Int {
            guard let children = attribute(element, name: kAXChildrenAttribute) as? [AXUIElement]
            else { return 0 }
            let remaining = OutlookComposeContextReader.maximumElements - queue.count
            if children.count > remaining { complete = false }
            queue.append(contentsOf: children.prefix(remaining))
            return children.count
        }

        mutating func element(_ root: AXUIElement, attribute name: String) -> AXUIElement? {
            guard let value = attribute(root, name: name),
                CFGetTypeID(value) == AXUIElementGetTypeID()
            else { return nil }
            // swiftlint:disable:next force_cast
            return (value as! AXUIElement)
        }

        mutating func string(_ element: AXUIElement, attribute name: String) -> String? {
            attribute(element, name: name) as? String
        }

        mutating func selectedRange(in element: AXUIElement) -> NSRange? {
            guard let value = attribute(element, name: kAXSelectedTextRangeAttribute),
                CFGetTypeID(value) == AXValueGetTypeID()
            else { return nil }
            // swiftlint:disable:next force_cast
            let axValue = value as! AXValue
            guard AXValueGetType(axValue) == .cfRange else { return nil }
            var range = CFRange()
            guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
            return NSRange(location: range.location, length: range.length)
        }

        private mutating func attribute(_ element: AXUIElement, name: String) -> CFTypeRef? {
            guard withinDeadline() else { return nil }
            guard let timeout = QuickActionContext.OutlookCaptureBudget.callTimeout(
                remaining: deadline - ContinuousClock.now)
            else {
                complete = false
                return nil
            }
            guard AXUIElementSetMessagingTimeout(element, timeout) == .success else {
                complete = false
                return nil
            }
            guard withinDeadline() else { return nil }
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            guard status == .success else {
                if status != .attributeUnsupported && status != .noValue { complete = false }
                return nil
            }
            return value
        }

        private mutating func withinDeadline() -> Bool {
            guard ContinuousClock.now < deadline else {
                complete = false
                return false
            }
            return true
        }
    }
}
