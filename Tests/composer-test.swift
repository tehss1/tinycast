import CoreGraphics
import CryptoKit
import Foundation

@main
@MainActor
struct ComposerTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() { passes += 1 } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() throws {
        try replacementBoundaries()
        repeatedDeliveryKeepsSignatureSpacing()
        paragraphFormattingRequiresWholeLines()
        selectedSubjectSurvivesCompletion()
        deliveryLabelMatchesInvocation()
        blankInitialRequestUsesEmailContext()
        firstFailureCanRetry()
        stopKeepsCompletedDraft()
        settledConversationReopens()
        fieldReopensOnlyForTheSameText()
        savedConversationIsViewOnly()
        manualEditsJoinConversation()
        try historyIsScopedAndRecoversInput()
        try historyStorageRecoversValidRecords()
        try historyKeyIsLazyAndWritesArePrivate()
        try updatedThreadKeepsConversation()
        newestQuoteIsIncluded()
        localizedQuoteIsIncluded()
        allRecipientsAreCaptured()
        contextIndicatorIsHonest()
        audienceOverrideSurvivesHistory()
        panelFollowsComposeArea()
        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func replacementBoundaries() throws {
        let prefix = "🙂 Draft:\n"
        let suffix = "\n\nSignature\nFrom: Customer\nNewest message"
        let original = prefix + "Rough notes" + suffix
        let range = NSRange(location: prefix.utf16.count, length: "Rough notes".utf16.count)
        let anchor = ComposerDraftAnchor(body: original, range: range)
        let changedDraft = "First paragraph.\n\nSecond paragraph.\n\nBest,\n\n"
        let changedBody = prefix + changedDraft + suffix
        let changedRange = anchor?.range(in: changedBody)
        expect(changedRange == NSRange(location: prefix.utf16.count, length: changedDraft.utf16.count),
            "caret reopening selects the whole changed draft, not the caret")
        if let changedRange, let swiftRange = Range(changedRange, in: changedBody) {
            var replaced = changedBody
            replaced.replaceSubrange(swiftRange, with: "Final draft")
            expect(replaced == prefix + "Final draft" + suffix,
                "replacement preserves both boundaries without duplicating the draft")
        }
        expect(anchor?.range(in: changedBody + "changed history") == nil,
            "a changed quote or signature invalidates automatic replacement")
        expect(anchor?.range(in: "Changed prefix" + changedBody) == nil,
            "a changed prefix invalidates automatic replacement")
        expect(anchor?.range(in: "short") == nil, "shorter unrelated bodies are refused")
        expect(ComposerDraftAnchor(body: "🙂", range: NSRange(location: 1, length: 0)) == nil,
            "a range splitting an emoji is refused")
        let insertion = ComposerDraftAnchor(body: suffix, range: NSRange(location: 0, length: 0))
        expect(insertion?.range(in: changedDraft + suffix)?.length == changedDraft.utf16.count,
            "an initially empty draft is tracked after insertion")
        let encoded = try JSONEncoder().encode(anchor)
        let decoded = try JSONDecoder().decode(ComposerDraftAnchor?.self, from: encoded)
        expect(decoded == anchor,
            "boundary fingerprints survive a relaunch")
        expect(String(data: encoded, encoding: .utf8)?.contains("Customer") == false,
            "anchors do not persist quoted email content")

        let richSignature = "\n\n\u{fffc} Alex Morgan\nFrom: Beth"
        let untouchedBoundary = ComposerDraftAnchor(
            body: richSignature, range: NSRange(location: 0, length: 0))
        expect(untouchedBoundary?.range(in: "Reply" + richSignature)
            == NSRange(location: 0, length: "Reply".utf16.count),
            "a caret insertion tracks the reply while preserving the rich signature")
        let previousAnchor = ComposerDraftAnchor(
            body: richSignature, range: NSRange(location: 0, length: 2))
        expect(previousAnchor?.rangePreservingTrailingLineBreaks(in: "Reply\n" + richSignature.dropFirst(2))
            == NSRange(location: 0, length: "Reply".utf16.count),
            "older draft anchors leave their captured signature boundary in place")

        let changedSignature = "\n\n\u{fffc} Updated signature\nFrom: Beth"
        let caret = NSRange(location: 0, length: 0)
        expect(ComposerDraftAnchor.restoredRange(
            in: changedSignature, anchor: untouchedBoundary, selectedRange: caret,
            insertsAtCaret: true) == caret,
            "a resumed Insert still targets the captured caret when Outlook changes its signature")
        expect(ComposerDraftAnchor.restoredRange(
            in: changedSignature, anchor: untouchedBoundary, selectedRange: caret,
            insertsAtCaret: false) == nil,
            "a resumed Replace cannot overwrite text when its saved boundary went stale")
        let explicitSelection = NSRange(location: 2, length: 1)
        expect(ComposerDraftAnchor.restoredRange(
            in: "A draft", anchor: untouchedBoundary, selectedRange: explicitSelection,
            insertsAtCaret: false) == explicitSelection,
            "a fresh selection still permits Replace after the saved boundary changes")
    }

    static func repeatedDeliveryKeepsSignatureSpacing() {
        let draft = "Please review.\n\nBest,"
        for lineBreak in ["\n", "\r\n"] {
            for count in 0...3 {
                let suffix = String(repeating: lineBreak, count: count) + (count > 0 ? "🙂 Signature" : "")
                var body = "Rough notes" + suffix
                var anchor = ComposerDraftAnchor(
                    body: body, range: NSRange(location: 0, length: "Rough notes".utf16.count))
                for _ in 0..<4 {
                    guard let range = anchor?.rangePreservingTrailingLineBreaks(in: body),
                        let selection = Range(range, in: body),
                        let boundaries = ComposerDraftAnchor.TextBoundaries(body: body, range: range)
                    else {
                        expect(false, "the reopened draft retains a valid replacement boundary")
                        break
                    }
                    anchor = ComposerDraftAnchor(body: body, range: range)
                    let delivery = QuickActionOutput.preparedForDelivery(
                        draft, action: .rewrite, toOutlook: true, boundaries: boundaries)
                    body.replaceSubrange(selection, with: delivery)
                    let expectedSuffix = String(repeating: "\n", count: max(0, 2 - count)) + suffix
                    expect(body == draft + expectedSuffix,
                        "reopening and replacing never accumulates signature paragraphs, including CRLF")
                }
            }
        }
    }

    static func paragraphFormattingRequiresWholeLines() {
        let draft = "First sentence. Second sentence."
        let split = "First sentence.\n\nSecond sentence."
        for (body, range, wholeLines) in [
            ("Rough notes\nSignature", NSRange(location: 0, length: 11), true),
            ("🙂 Rough notes", NSRange(location: 3, length: 11), false),
            ("Rough notes continue", NSRange(location: 0, length: 11), false),
            ("🙂 Rough notes continue", NSRange(location: 3, length: 11), false),
            ("", NSRange(location: 0, length: 0), true),
            ("Intro\n\nSignature", NSRange(location: 6, length: 0), true),
            ("Intro text", NSRange(location: 5, length: 0), false),
            ("Intro text", NSRange(location: 10, length: 0), false),
        ] {
            let boundaries = ComposerDraftAnchor.TextBoundaries(body: body, range: range)
            expect(boundaries?.coversWholeLines == wholeLines,
                "formatting uses actual UTF-16 replacement and caret boundaries")
            let delivery = QuickActionOutput.preparedForDelivery(
                draft, action: .rewrite, toOutlook: true, insertsAtCaret: range.length == 0,
                boundaries: boundaries)
            let trailing = range.length == 0
                && boundaries?.followingLineBreakCount == 0 ? "\n" : ""
            expect(delivery == (wholeLines ? split : draft) + trailing,
                "only whole-line replacements and carets on empty lines split into paragraphs")
        }
        expect(QuickActionOutput.preparedForDelivery(
            draft, action: .rewrite, toOutlook: true) == draft,
            "missing target boundaries preserve the existing paragraph")
        expect(ComposerDraftAnchor.TextBoundaries(
            body: "🙂", range: NSRange(location: 8, length: 0)) == nil,
            "out-of-bounds targets cannot request paragraph formatting")
    }

    static func selectedSubjectSurvivesCompletion() {
        let subject = "Subject: Call tomorrow"
        let state = QuickActionPanelState(action: .rewrite, original: subject,
            targetLanguage: Locale.Language(identifier: "en"))
        state.finish(subject)
        expect(state.output == subject && state.canReplace,
            "a subject-only selection finishes successfully and can replace the original")
        expect(state.historyRecord()?.latestDraft == subject,
            "saving and reopening never strips the user's own subject")
        let source = "Ready—send it."
        let voiced = QuickActionPanelState(action: .rewrite, original: source,
            targetLanguage: Locale.Language(identifier: "en"))
        voiced.finish(source)
        expect(voiced.output == source, "completion preserves punctuation from the selected source")
        voiced.adoptSourceDraft("Subject: My manual edit\n\nReady—send it.")
        voiced.refinementInstruction = "Keep this wording"
        _ = voiced.beginRefinement()
        let manual = "Subject: My manual edit\n\nReady—send it."
        voiced.finish(manual)
        expect(voiced.output == manual, "refinement protects the latest manual source subject and dash")
        expect(voiced.historyRecord()?.latestDraft == manual,
            "history preserves subjects introduced by the user's manual edit")
    }

    static func makeState(caret: Bool = true) -> QuickActionPanelState {
        QuickActionPanelState(action: .rewrite, original: caret ? "" : "Rough notes",
            targetLanguage: Locale.Language(identifier: "en"), awaitsWritingInstruction: caret)
    }

    static func deliveryLabelMatchesInvocation() {
        expect(makeState().deliveryActionTitle == "Insert",
            "Composer offers Insert when Hyper+R captured only a caret")
        expect(makeState(caret: false).deliveryActionTitle == "Replace",
            "Composer offers Replace when Hyper+R captured selected text")

        let record = makeState().historyRecord()!
        let restoredAtCaret = QuickActionPanelState(
            restoring: record, context: nil,
            targetLanguage: Locale.Language(identifier: "en"), insertsAtCaret: true)
        let restoredFromSelection = QuickActionPanelState(
            restoring: record, context: nil,
            targetLanguage: Locale.Language(identifier: "en"), insertsAtCaret: false)
        expect(restoredAtCaret.deliveryActionTitle == "Insert",
            "a resumed conversation keeps the action from the current caret invocation")
        expect(restoredFromSelection.deliveryActionTitle == "Replace",
            "a resumed conversation keeps the action from the current selection invocation")
    }

    static func blankInitialRequestUsesEmailContext() {
        let context = QuickActionContext(
            recipient: "Client <client@example.com>", subject: "Question",
            recentThread: "From: Client\nCould you confirm whether this is ready?")
        let state = QuickActionPanelState(
            action: .rewrite, original: "", context: context,
            targetLanguage: Locale.Language(identifier: "en"), awaitsWritingInstruction: true)

        expect(state.canRefine, "captured email context enables a blank first request")
        let instruction = state.beginInitialRewrite()
        expect(instruction == QuickActionPanelState.contextOnlyInstruction,
            "blank Return asks for a response based only on the captured email")
        expect(state.conversation.first?.text == QuickActionPanelState.contextOnlyInstruction,
            "the context-only request remains visible in the Composer conversation")

        let envelopeOnly = QuickActionPanelState(
            action: .rewrite, original: "",
            context: QuickActionContext(
                recipient: "client@example.com", subject: "Question", recentThread: nil),
            targetLanguage: Locale.Language(identifier: "en"), awaitsWritingInstruction: true)
        expect(!envelopeOnly.canRefine,
            "a recipient and subject alone cannot silently produce an invented reply")
        expect(envelopeOnly.beginInitialRewrite() == nil,
            "blank Return stays inert when no email body was captured")

        state.finish("Could you confirm whether this is ready?")
        expect(!state.canRefine,
            "a blank later refinement never resubmits or regenerates the draft")
    }

    static func firstFailureCanRetry() {
        let state = makeState()
        state.refinementInstruction = "Offer a call tomorrow"
        expect(state.beginInitialRewrite() != nil, "initial request starts")
        state.append("Partial")
        state.fail("The connection failed")
        expect(state.output.isEmpty && !state.canReplace, "a failed partial draft cannot replace text")
        expect(state.conversation.last?.state == .failed, "the streaming row becomes an error")
        expect(state.conversation.last?.text == "The connection failed", "the error is visible in chat")
        expect(state.refinementInstruction == "Offer a call tomorrow", "failed input is recovered")
        expect(state.canRefine, "the first request can be retried")
        expect(state.beginInitialRewrite() != nil, "retry starts a new request")
        state.finish("Could we schedule a call tomorrow?")
        expect(state.canReplace && state.refinementInstruction.isEmpty, "successful retry clears input")
        expect(state.canDeliver(isViewingActive: true),
            "Command+Enter can deliver as soon as the draft finishes")
        expect(!state.canDeliver(isViewingActive: false),
            "Command+Enter cannot deliver while viewing an archived conversation")

        let subjectState = makeState()
        subjectState.finish("Subject: Call tomorrow\n\nCould we schedule a call tomorrow?")
        expect(subjectState.output == "Could we schedule a call tomorrow?",
            "a completed Composer draft contains body text only")
        expect(subjectState.conversation.last?.text == "Could we schedule a call tomorrow?",
            "Composer history stores the sanitized draft")

        let legacySubjectRecord = RewriteHistoryRecord(
            id: UUID(), createdAt: Date(), updatedAt: Date(), subject: "Call tomorrow",
            recipient: nil, original: "", messages: [
                RewriteConversationMessage(
                    role: .assistant,
                    text: "Subject: Call tomorrow\n\nCould we schedule a call tomorrow?",
                    state: .complete)
            ])
        expect(legacySubjectRecord.preview == "Subject: Call tomorrow Could we schedule a call tomorrow?",
            "saved previews preserve subjects when their provenance is unavailable")
        expect(legacySubjectRecord.latestDraft == "Subject: Call tomorrow\n\nCould we schedule a call tomorrow?",
            "restoring a stored draft never guesses whether its subject was user-authored")

        let selection = makeState(caret: false)
        selection.fail("No provider")
        expect(selection.canRefine && selection.conversation.last?.state == .failed,
            "selected-text failures are also retryable and visible")
        expect(selection.retriesOriginalRequest, "a failed selection retries without new words")
        for record in [makeState(caret: false).historyRecord()!, selection.historyRecord()!] {
            let reopened = QuickActionPanelState(restoring: record, context: nil,
                targetLanguage: Locale.Language(identifier: "en"), insertsAtCaret: false)
            expect(!reopened.isAwaitingInstruction && reopened.retriesOriginalRequest,
                "a reopened selection without a draft retries rather than awaiting a request")
        }
        let caretRecord = makeState().historyRecord()!
        expect(QuickActionPanelState(restoring: caretRecord, context: nil,
            targetLanguage: Locale.Language(identifier: "en"), insertsAtCaret: true)
            .isAwaitingInstruction, "a reopened caret conversation still awaits its first request")

        let contextOnly = QuickActionPanelState(
            action: .rewrite, original: "",
            context: QuickActionContext(
                recipient: "client@example.com", subject: "Question",
                recentThread: "From: Client\nIs this ready?"),
            targetLanguage: Locale.Language(identifier: "en"), awaitsWritingInstruction: true)
        expect(contextOnly.beginInitialRewrite() != nil, "a blank request drafts from the thread")
        contextOnly.fail("No provider")
        expect(contextOnly.refinementInstruction.isEmpty,
            "the stand-in request never appears in the field")
        expect(contextOnly.canRefine, "a failed blank request can be retried")

        let voiced = makeState()
        voiced.finish("This is all set—we assigned the license.")
        expect(voiced.output == "This is all set. We assigned the license.",
            "a finished model draft loses its em dash")
    }

    static func stopKeepsCompletedDraft() {
        let state = makeState(caret: false)
        state.finish("Last good draft")
        state.refinementInstruction = "Make it warmer"
        _ = state.beginRefinement()
        state.append("Partial revised")
        state.fail("Stopped")
        expect(state.output == "Last good draft" && state.canReplace,
            "stopping preserves the last completed draft")
        expect(state.refinementInstruction == "Make it warmer", "stopping restores the request")
        state.append("Late token")
        expect(state.output == "Last good draft", "late streaming tokens cannot alter a stopped draft")
        let retry = state.beginRefinement()
        expect(retry?.messages.filter { $0.role == .user }.count == 1,
            "retry does not resend failed requests twice")
        let interrupted = state.historyRecord()
        expect(interrupted?.pendingInstruction == "Make it warmer",
            "in-flight input is durable before completion")
        if let interrupted {
            let restored = QuickActionPanelState(restoring: interrupted, context: nil,
                targetLanguage: Locale.Language(identifier: "en"), insertsAtCaret: true)
            expect(!restored.conversation.contains { $0.state == .streaming },
                "relaunch never leaves an abandoned streaming row")
            expect(restored.refinementInstruction == "Make it warmer" && restored.canRefine,
                "interrupted requests can resume after relaunch")
            let resumedRequest = restored.beginRefinement()
            expect(resumedRequest?.messages.filter { $0.role == .user }.count == 1,
                "relaunch does not replay the interrupted request twice")
        }
    }

    static func settledConversationReopens() {
        let state = makeState(caret: false)
        expect(!state.reopensFromSource, "a conversation still generating is not reopened from its field")
        state.finish("Finished draft")
        expect(state.reopensFromSource, "a finished conversation reopens from the field it came from")
        state.refinementInstruction = "Shorter"
        _ = state.beginRefinement()
        state.finish("Shorter draft")
        expect(state.reopensFromSource, "a conversation stays reopenable after another refinement")
        let caret = makeState()
        expect(caret.reopensFromSource, "an unsent caret request reopens with what was typed")
        caret.replacementIssue = "Couldn't capture this Outlook draft. Reopen Composer to try again."
        expect(!caret.reopensFromSource, "a replacement issue makes the next press capture afresh")
    }

    static func fieldReopensOnlyForTheSameText() {
        let selected = makeState(caret: false)
        selected.finish("Finished draft")
        let range = NSRange(location: 4, length: 11)
        func reopens(
            _ state: QuickActionPanelState, _ selection: NSRange?, _ pressed: NSRange?,
            count: Int? = nil, pressedCount: Int? = nil, text: String? = nil
        ) -> Bool {
            state.reopensFromField(
                selection: selection, pressedSelection: pressed, characterCount: count,
                pressedCharacterCount: pressedCount, selectedText: { text })
        }
        expect(reopens(selected, range, range, text: "Rough\n  notes "),
            "the same selected text reopens, whatever its whitespace")
        expect(!reopens(selected, range, range, text: "Other notes"),
            "different text in the same range starts a new conversation")
        expect(!reopens(selected, range, range),
            "unreadable selected text starts a new conversation")
        expect(!reopens(selected, nil, range, text: "Rough notes"),
            "a field that reported no range never reopens for a later selection")
        expect(!reopens(selected, nil, nil, text: "Rough notes"),
            "a field that never reports a range never reopens")

        let caret = makeState()
        let point = NSRange(location: 0, length: 0)
        expect(reopens(caret, point, point, count: 0, pressedCount: 0),
            "an unchanged field reopens its caret conversation")
        expect(!reopens(caret, point, point, count: 0, pressedCount: 12),
            "a field edited since the press starts a new conversation")
        expect(!reopens(caret, point, point),
            "a field that cannot report its length starts a new conversation")
        expect(!reopens(caret, point, NSRange(location: 0, length: 5), count: 0, pressedCount: 0,
            text: "Hello"), "a selection where the caret was starts a new conversation")
    }

    static func savedConversationIsViewOnly() {
        let state = makeState(caret: false)
        state.finish("Finished draft")
        expect(state.isViewingActive && state.canDeliver(isViewingActive: state.isViewingActive),
            "the active conversation can be delivered")
        state.viewedHistoryID = UUID()
        expect(!state.isViewingActive && !state.canDeliver(isViewingActive: state.isViewingActive),
            "a saved conversation on screen is view and copy only")
        state.viewedHistoryID = state.historyID
        expect(state.isViewingActive, "returning to the active row restores its controls")
    }

    static func manualEditsJoinConversation() {
        let state = makeState(caret: false)
        state.finish("Generated draft")
        state.adoptSourceDraft("Rough notes")
        expect(state.output == "Generated draft", "unchanged rough notes do not replace the saved draft")
        state.adoptSourceDraft("I edited this in Outlook.")
        expect(state.output == "I edited this in Outlook.", "manual edits become the current draft")
        let own = "Ready—send it. Thanks for reaching out."
        state.adoptSourceDraft(own)
        expect(state.output == own, "the reader's own wording is adopted untouched")
        expect(state.historyRecord()?.latestDraft == own, "history keeps the reader's own wording")
        let delivered = QuickActionOutput.preparedForDelivery(
            state.output, action: .rewrite, toOutlook: false)
        expect(delivered == own, "delivery returns the reader's own wording")
        state.adoptSourceDraft("I edited this in Outlook.")
        let count = state.conversation.count
        state.adoptSourceDraft("I edited this in Outlook.\n")
        expect(state.conversation.count == count, "formatting-only differences do not duplicate turns")
        state.refinementInstruction = "Shorten it"
        let request = state.beginRefinement()
        expect(request?.draft == "I edited this in Outlook.", "refinement starts from the manual edit")
        expect(request?.messages.contains { $0.text == "I edited this in Outlook." } == true,
            "the manual draft reaches the model conversation")
        state.fail("Stopped")
        state.replacementIssue = "Select the draft again"
        expect(!state.canReplace && state.canRefine, "an unsafe target still permits refinement")
    }

    static func historyIsScopedAndRecoversInput() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComposerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let store = RewriteHistoryStore(directory: directory, key: { historyKey }, now: { clock })
        let context = QuickActionContext(recipient: "Client", subject: "Question", recentThread: nil,
            documentIdentity: "outlook-editor-A")
        let state = QuickActionPanelState(action: .rewrite, original: "", context: context,
            targetLanguage: Locale.Language(identifier: "en"), createdAt: clock,
            awaitsWritingInstruction: true)
        state.refinementInstruction = "Unsent first request"
        guard let pending = state.historyRecord(now: clock) else {
            expect(false, "pending history exists")
            return
        }
        expect(store.save(pending), "pending new-email request is saved")
        expect(store.resumableRecord(selection: "", context: context)?.pendingInstruction
            == "Unsent first request", "a new email without a quote restores its first request")
        let other = QuickActionContext(recipient: "Client", subject: "Question", recentThread: nil,
            documentIdentity: "outlook-editor-B")
        expect(store.resumableRecord(selection: "", context: other) == nil,
            "another compose editor with the same envelope does not inherit pending input")
        expect(store.resumableRecord(selection: "", context: nil) == nil,
            "an unrelated empty text field cannot resume Outlook history")
        state.finish("Saved draft")
        if let completed = state.historyRecord(now: clock) { _ = store.save(completed) }
        expect(store.resumableRecord(selection: "Saved draft", context: nil) == nil,
            "matching text in another app cannot resume an Outlook conversation")
        let reloaded = RewriteHistoryStore(directory: directory, key: { historyKey }, now: { clock })
        reloaded.load()
        expect(reloaded.resumableRecord(selection: "", context: context)?.id == state.historyID,
            "same-editor history matching survives a Tinycast relaunch")
        clock = clock.addingTimeInterval(RewriteHistoryStore.retention + 1)
        expect(store.savePendingInstruction("Expired input", id: state.historyID),
            "pending-input persistence still succeeds when pruning expired records")
        expect(store.records.isEmpty, "typing cannot keep expired history on disk")
    }

    static func newestQuoteIsIncluded() {
        let body = """
            Signature
            On Thursday, Client wrote:
            Newest question
            From: Colleague
            Second newest
            On Wednesday, Another Client wrote:
            Old question
            """
        let context = QuickActionContext.outlook(body: body, selectedRange: NSRange(location: 0, length: 0),
            recipient: nil, subject: nil)
        expect(context?.recentThread?.contains("Newest question") == true,
            "On-wrote headers begin the newest message")
        expect(context?.recentThread?.contains("Second newest") == true, "second newest message stays")
        expect(context?.recentThread?.contains("Old question") == false, "older messages remain excluded")
        expect(context?.recentThread?.contains("Signature") == false, "draft signature remains excluded")
        expect(context?.historyFingerprints.count == 3,
            "history matching fingerprints the full quote without sending older messages")
    }

    static func localizedQuoteIsIncluded() {
        let body = """
            Signature
            Am Donnerstag, Kundin schrieb:
            Neueste Frage
            Von: Kollege
            Zweite Frage
            """
        let context = QuickActionContext.outlook(body: body, selectedRange: NSRange(location: 0, length: 0),
            recipient: nil, subject: nil)
        expect(context?.recentThread?.contains("Neueste Frage") == true,
            "a reply attribution in another language begins the newest message")
        expect(context?.recentThread?.contains("Signature") == false,
            "the draft signature stays out of a localized thread")
    }

    static func updatedThreadKeepsConversation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComposerThreadTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RewriteHistoryStore(directory: directory, key: { historyKey })
        let originalContext = QuickActionContext(
            recipient: "Client <client@example.com>", subject: "Project update",
            recentThread: "From: Client\nFirst question\nFrom: Alex\nEarlier reply")
        let state = QuickActionPanelState(
            action: .rewrite, original: "", context: originalContext,
            targetLanguage: Locale.Language(identifier: "en"), awaitsWritingInstruction: true)
        state.refinementInstruction = "Send an update"
        _ = state.beginInitialRewrite()
        state.finish("Here is the update.")
        expect(store.save(state.historyRecord()!), "thread history is saved")

        let updatedContext = QuickActionContext(
            recipient: "Client <client@example.com>; Vendor <vendor@example.com>",
            subject: "Project update",
            recentThread: "From: Client\nNewest reply\nFrom: Client\nFirst question")
        let resumed = store.resumableRecord(selection: "", context: updatedContext)
        expect(resumed?.id == state.historyID,
            "an overlapping quoted message keeps a new reply in the same conversation")
        expect(resumed?.contextFingerprints == updatedContext.historyFingerprints,
            "resuming advances the stored message fingerprints")

        let unrelatedContext = QuickActionContext(
            recipient: "Client <client@example.com>", subject: "Project update",
            recentThread: "From: Client\nAn unrelated message")
        expect(store.resumableRecord(selection: "", context: unrelatedContext) == nil,
            "the same envelope without a shared message does not merge conversations")
    }

    static func allRecipientsAreCaptured() {
        let recipients = QuickActionContext.outlookRecipients(from: [
            "\u{fffc}\u{fffc}\u{fffc}", "To:",
            "Integration, alerts@example.com, Offline",
            "Nick, nick@example.com, Presence Unknown",
            "Brandon, brandon@example.com, Presence Unknown",
            "nick@example.com", "NICK@example.com"
        ])
        expect(recipients == "Integration <alerts@example.com>; Nick <nick@example.com>; Brandon <brandon@example.com>",
            "every Outlook recipient chip is captured once, in order, without presence text")
        expect(QuickActionContext.outlookRecipients(from: ["one@example.com; two@example.com"])
            == "one@example.com; two@example.com", "plain multi-address fields retain every address")
        expect(QuickActionContext.outlookRecipients(from: ["Bcc: hidden@example.com"])
            == "hidden@example.com", "Bcc field labels do not become recipient names")
        expect(QuickActionContext.outlookRecipients(from: ["To:", "\u{fffc}", "Presence Unknown"]) == nil,
            "field labels and token placeholders do not become recipients")
        expect(QuickActionContext.outlookRecipients(from: ["Smith, Jane, jane+work@example.co.uk, Busy"])
            == "\"Smith, Jane\" <jane+work@example.co.uk>", "commas in names and tagged addresses survive")
        expect(EmailAddressPattern.recipientDomains(
            in: QuickActionContext.outlookRecipients(from: ["Smith, Jane, jane@example.org, Busy"]) ?? "")
            == ["example.org"], "a quoted name with a comma still resolves to one recipient")
        let many = (0..<50).map { "Person \($0), person\($0)@example.com, Offline" }
        expect(QuickActionContext.outlookRecipients(from: many)?.components(separatedBy: "; ").count == 50,
            "recipient aggregation does not keep only the longest chip")
    }

    static func contextIndicatorIsHonest() {
        let captured = QuickActionContext(recipient: "one@example.com", subject: "Question",
            recentThread: "From: Client\nA question")
        expect(captured.captureTitle == "Email context captured", "complete snapshot reports captured")
        let envelope = QuickActionContext(recipient: "one@example.com", subject: "Question", recentThread: nil)
        expect(envelope.captureTitle == "Partial email context", "subject alone never implies body capture")
        let threadOnly = QuickActionContext(recipient: nil, subject: nil, recentThread: "From: Client\nQuestion")
        expect(threadOnly.captureTitle == "Partial email context", "missing envelope reports partial capture")
        let empty = QuickActionContext(recipient: nil, subject: nil, recentThread: nil, documentIdentity: "editor")
        expect(empty.captureTitle == "Email context unavailable", "editor identity is not email context")
    }

    static func audienceOverrideSurvivesHistory() {
        let context = QuickActionContext(
            recipient: "Coworker <person@example.org>", subject: "Question",
            recentThread: "From: Coworker\nCould you check this?")
        let state = QuickActionPanelState(
            action: .rewrite, original: "", context: context,
            targetLanguage: Locale.Language(identifier: "en"), awaitsWritingInstruction: true)
        expect(
            state.detectedComposerAudience(internalDomains: "example.org")
                == .internalRecipients,
            "Composer detects an internal recipient from the captured email")
        let mixed = QuickActionContext(
            recipient: "Coworker <person@example.org>; Client <client@example.com>",
            subject: "Question", recentThread: nil)
        let mixedState = QuickActionPanelState(
            action: .rewrite, original: "", context: mixed,
            targetLanguage: Locale.Language(identifier: "en"), awaitsWritingInstruction: true)
        expect(
            mixedState.detectedComposerAudience(internalDomains: "example.org")
                == .externalRecipients,
            "an external Cc or Bcc recipient keeps the safer external tone")
        expect(
            ComposerAudience.normalizedDomains(
                in: "example.org; support.example.org; bad_domain; localhost")
                == ["example.org", "support.example.org"],
            "only valid internal domains are normalized")
        expect(
            ComposerAudience.invalidDomains(
                in: "example.org; bad_domain; localhost") == ["bad_domain", "localhost"],
            "invalid internal domains are available to the settings warning")
        state.audienceOverride = .externalRecipients
        expect(
            state.composerAudience(internalDomains: "example.org") == .externalRecipients,
            "a manual audience choice overrides automatic detection")
        guard let record = state.historyRecord() else {
            expect(false, "the audience override has a history record")
            return
        }
        let restored = QuickActionPanelState(
            restoring: record, context: context,
            targetLanguage: Locale.Language(identifier: "en"), insertsAtCaret: true)
        expect(
            restored.audienceOverride == .externalRecipients
                && restored.composerAudience(internalDomains: "example.org")
                    == .externalRecipients,
            "the audience override follows the same email conversation")
    }

    static func historyStorageRecoversValidRecords() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComposerLossyHistory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rewrite-history.sealed")
        let timestamp = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let record = RewriteHistoryRecord(
            id: UUID(), createdAt: timestamp, updatedAt: timestamp, subject: nil, recipient: nil,
            original: "Keep this draft", messages: [])
        guard let valid = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record))
            as? [String: Any]
        else { fatalError("the history fixture must encode as an object") }
        var malformed = valid
        malformed["id"] = "not-a-uuid"
        let mixed: [Any] = [malformed, valid, NSNull(), ["futureSchema": true], valid]
        let data = try JSONSerialization.data(withJSONObject: mixed)
        let sealed = try AES.GCM.seal(data, using: historyKey).combined!
        try sealed.write(to: file)
        let staged = directory.appendingPathComponent(".rewrite-history-\(UUID().uuidString)")
        try sealed.write(to: staged)
        let store = RewriteHistoryStore(directory: directory, key: { historyKey }, now: { timestamp })
        store.load()
        expect(!FileManager.default.fileExists(atPath: staged.path),
            "a staged write a crash left behind is removed on load")
        expect(store.records == [record, record],
            "bad records before and between valid records do not discard valid history")
        let preserved = try Data(contentsOf: file)
        expect(preserved == sealed,
            "lossy decoding preserves the encrypted source file")

        let malformedData = try AES.GCM.seal(Data("not json".utf8), using: historyKey).combined!
        try malformedData.write(to: file)
        let unreadable = RewriteHistoryStore(directory: directory, key: { historyKey }, now: { timestamp })
        unreadable.load()
        expect(unreadable.records.isEmpty && FileManager.default.fileExists(atPath: file.path),
            "an authenticated file with invalid JSON is left intact")

        let wrongKey = SymmetricKey(size: .bits256)
        let unauthenticated = RewriteHistoryStore(directory: directory, key: { wrongKey }, now: { timestamp })
        unauthenticated.load()
        let before = try Data(contentsOf: file)
        expect(!unauthenticated.save(record),
            "a file that fails AES-GCM authentication blocks saves")
        expect((try? Data(contentsOf: file)) == before,
            "a file that fails AES-GCM authentication is preserved")
    }

    static func historyKeyIsLazyAndWritesArePrivate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComposerPrivateHistory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = directory.appendingPathComponent("rewrite-history.json")
        try Data("obsolete private draft".utf8).write(to: legacy)
        var keyReads = 0
        let store = RewriteHistoryStore(directory: directory, key: {
            keyReads += 1
            return historyKey
        })
        store.load()
        expect(keyReads == 0, "an absent history file never opens Keychain at launch")
        expect(!FileManager.default.fileExists(atPath: legacy.path),
            "obsolete plaintext is removed even when no encrypted history exists")
        let record = RewriteHistoryRecord(
            id: UUID(), createdAt: Date(), updatedAt: Date(), subject: nil, recipient: nil,
            original: "Private draft", messages: [])
        expect(store.save(record), "the first save creates encrypted history")
        expect(keyReads == 1, "the first save loads the key once")
        let file = directory.appendingPathComponent("rewrite-history.sealed")
        for _ in 0..<2 {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                "new and atomically replaced history files are owner-only")
            let resources = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
            expect(resources.isExcludedFromBackup == true,
                "new and atomically replaced history files stay excluded from backup")
            expect(store.save(record), "replacing encrypted history succeeds")
        }
        expect(keyReads == 1, "later saves reuse the same key")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let marker = file.appendingPathComponent("keep")
        try Data("unchanged".utf8).write(to: marker)
        var changed = record
        changed.pendingInstruction = "Must not land"
        expect(!store.save(changed), "a failed atomic replacement reports failure")
        expect(store.records == [record], "a failed replacement leaves published history unchanged")
        let preservedMarker = try String(contentsOf: marker, encoding: .utf8)
        expect(preservedMarker == "unchanged",
            "a failed replacement leaves the existing destination unchanged")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        expect(remaining == ["rewrite-history.sealed"], "failed writes remove only their staging file")
    }

    static func panelFollowsComposeArea() {
        let primary = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let secondary = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
        let source = CGRect(x: -1700, y: 400, width: 1400, height: 700)
        let size = CGSize(width: 740, height: 420)
        expect(ComposerPanelPlacement.screenIndex(for: source, screens: [primary, secondary]) == 1,
            "the compose editor chooses its display independently of the pointer")
        let frame = ComposerPanelPlacement.centeredFrame(
            size: size, source: source, visibleScreen: secondary, margin: 8)
        expect(frame.midX == source.midX && frame.midY == source.midY,
            "Composer centers over the visible compose area")
        expect(frame.size == size, "placement does not change the panel size")
        let longEditor = CGRect(x: 200, y: -2000, width: 1200, height: 2800)
        let window = CGRect(x: 100, y: 100, width: 1400, height: 850)
        expect(ComposerPanelPlacement.sourceFrame(editor: longEditor, window: window)
            == longEditor.intersection(window), "long quoted emails anchor to the visible editor")
        expect(ComposerPanelPlacement.sourceFrame(editor: .zero, window: window) == window,
            "missing editor geometry falls back to the compose window")
        let edge = CGRect(x: 1450, y: 920, width: 40, height: 40)
        let edgeFrame = ComposerPanelPlacement.centeredFrame(
            size: size, source: edge, visibleScreen: primary, margin: 8)
        expect(primary.insetBy(dx: 8, dy: 8).contains(edgeFrame),
            "edge placement stays clear of the screen boundaries")
        let grown = CGRect(x: frame.minX, y: frame.maxY - 650, width: frame.width, height: 650)
        let clamped = ComposerPanelPlacement.clamped(grown, to: secondary, margin: 8)
        expect(secondary.contains(clamped) && clamped.minX == frame.minX,
            "a growing panel stays on the source display")
        let above = CGRect(x: 0, y: 982, width: 1512, height: 982)
        expect(ComposerPanelPlacement.screenIndex(for: above, screens: [primary, above]) == 1,
            "vertically arranged displays use the same coordinate space")
    }
}

private let historyKey = SymmetricKey(size: .bits256)
