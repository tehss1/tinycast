import CoreGraphics
import CryptoKit
import Foundation
import os

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
        insertedParagraphSurvivesReplace()
        selectedParagraphKeepsSurroundingBreaks()
        selectedLineKeepsItsBreaksOutsideOutlook()
        paragraphFormattingRequiresWholeLines()
        selectedSubjectSurvivesCompletion()
        openerOnlyReplyFails()
        deliveryLabelMatchesInvocation()
        resumedTargetFollowsThePress()
        resumedSourceDecision()
        differentSelectionRequiresRewrite()
        try selectedSourceSurvivesInterruption()
        failedFirstRewriteKeepsSourceDashes()
        explicitSelectionReanchorsDraft()
        savedDraftAndCaretKeepTheirBehavior()
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
        try historyKeyWaitsOffTheMainActor()
        try updatedThreadKeepsConversation()
        try separateRepliesKeepSeparateConversations()
        historyFollowsEditorAndRecipients()
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
        expect(previousAnchor?.rangePreservingLineBreaks(in: "Reply\n" + richSignature.dropFirst(2))
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

    static func insertedParagraphSurvivesReplace() {
        for following in ["", "\nSignature"] {
            var body = "Intro text" + following
            let caret = NSRange(location: "Intro text".utf16.count, length: 0)
            let anchor = ComposerDraftAnchor(body: body, range: caret)
            let insert = QuickActionOutput.preparedForDelivery(
                "Hello.", action: .rewrite, toOutlook: true, insertsAtCaret: true,
                boundaries: ComposerDraftAnchor.TextBoundaries(body: body, range: caret))
            body.insert(contentsOf: insert, at: Range(caret, in: body)!.lowerBound)
            let pressed = NSRange(location: caret.location + insert.utf16.count, length: 0)
            guard let range = ComposerDraftAnchor.restoredRange(
                in: body, anchor: anchor, selectedRange: pressed, insertsAtCaret: false),
                let selection = Range(range, in: body)
            else {
                expect(false, "the inserted draft is found again after delivery")
                continue
            }
            expect(body[selection] == "Hello.",
                "a reopened insertion targets only the draft, never its paragraph separator")
            let replace = QuickActionOutput.preparedForDelivery(
                "Hi there.", action: .rewrite, toOutlook: true,
                boundaries: ComposerDraftAnchor.TextBoundaries(body: body, range: range))
            body.replaceSubrange(selection, with: replace)
            expect(body.hasPrefix("Intro text\n\nHi there.\n"),
                "replacing an inserted paragraph keeps it apart from the line before")
        }
    }

    /// Outlook drops a trailing line break from pasted text, so delivery must never depend on one.
    static func selectedParagraphKeepsSurroundingBreaks() {
        for lineBreak in ["\n", "\r\n"] {
            let paragraph = "The rerun passed. I'll look into the failure this afternoon."
            let lead = "Hi," + lineBreak + lineBreak
            let tail = lineBreak + lineBreak + "Thanks!"
            var body = lead + paragraph + tail
            let tripleClick = NSRange(
                location: lead.utf16.count, length: (paragraph + lineBreak).utf16.count)
            for pressed in [tripleClick, NSRange(location: lead.utf16.count, length: paragraph.utf16.count)] {
                let range = ComposerDraftAnchor.replacementRange(in: body, selectedRange: pressed)
                expect(range == NSRange(location: lead.utf16.count, length: paragraph.utf16.count),
                    "a selected paragraph is replaced without its own trailing line break")
                let resumed = ComposerDraftAnchor.restoredRange(
                    in: body, anchor: nil, selectedRange: pressed, insertsAtCaret: false)
                expect(resumed == range, "a resumed conversation replaces the same paragraph text")
            }
            let range = ComposerDraftAnchor.replacementRange(in: body, selectedRange: tripleClick)
            let delivery = QuickActionOutput.preparedForDelivery(
                "Rerun passed. Looking into it today.", action: .rewrite, toOutlook: true,
                boundaries: ComposerDraftAnchor.TextBoundaries(body: body, range: range))
            expect(delivery.last?.isNewline == false,
                "a selected paragraph's delivery ends without a line break for Outlook to drop")
            body.replaceSubrange(Range(range, in: body)!, with: delivery)
            expect(body == lead + "Rerun passed.\n\nLooking into it today." + tail,
                "the blank lines around a replaced paragraph stay where they were")
        }
        let blankLines = "A\n\n\nB"
        let blank = ComposerDraftAnchor.replacementRange(
            in: blankLines, selectedRange: NSRange(location: 2, length: 1))
        expect(blank.length == 0 && NSMaxRange(blank) <= blankLines.utf16.count,
            "a selection of only line breaks keeps them and targets a position inside the body")
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
                    guard let range = anchor?.rangePreservingLineBreaks(in: body),
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

    /// Outside Outlook the selection itself is replaced, line breaks and all, so they come back.
    static func selectedLineKeepsItsBreaksOutsideOutlook() {
        for lineBreak in ["\n", "\r\n"] {
            let lead = "Hi," + lineBreak + lineBreak
            let tail = lineBreak + "Thanks" + lineBreak
            let selection = "the rerun passd and i will check the deploy job tomorow." + lineBreak
            var body = lead + selection + tail
            for result in ["The rerun passed. I'll check the deploy job tomorrow.",
                "The rerun passed. I'll check the deploy job tomorrow.\n"]
            {
                let delivery = QuickActionOutput.preparedForDelivery(
                    result, action: .rewrite, toOutlook: false, replacing: selection)
                body = lead + selection + tail
                body.replaceSubrange(body.range(of: selection)!, with: delivery)
                expect(body == lead + "The rerun passed. I'll check the deploy job tomorrow."
                    + lineBreak + tail, "a triple-clicked line keeps the blank line below it")
            }
        }
        expect(QuickActionOutput.preparedForDelivery(
            "Fixed.", action: .rewrite, toOutlook: false, replacing: "\nfixd") == "\nFixed.",
            "a selection's leading line break comes back too")
        expect(QuickActionOutput.preparedForDelivery(
            "Fixed\n", action: .rewrite, toOutlook: false, replacing: "fixd") == "Fixed\n",
            "a selection without edge line breaks leaves the result as it was")
    }

    static func paragraphFormattingRequiresWholeLines() {
        let draft = "First sentence. Second sentence."
        let split = "First sentence.\n\nSecond sentence."
        for (body, range, wholeLines, leading) in [
            ("Rough notes\nSignature", NSRange(location: 0, length: 11), true, ""),
            ("🙂 Rough notes", NSRange(location: 3, length: 11), false, ""),
            ("Rough notes continue", NSRange(location: 0, length: 11), false, ""),
            ("🙂 Rough notes continue", NSRange(location: 3, length: 11), false, ""),
            ("", NSRange(location: 0, length: 0), true, ""),
            ("Intro\n\nSignature", NSRange(location: 6, length: 0), true, ""),
            ("Intro text", NSRange(location: 5, length: 0), false, ""),
            ("Intro text", NSRange(location: 10, length: 0), false, "\n\n"),
        ] {
            let boundaries = ComposerDraftAnchor.TextBoundaries(body: body, range: range)
            expect(boundaries?.coversWholeLines == wholeLines,
                "formatting uses actual UTF-16 replacement and caret boundaries")
            let delivery = QuickActionOutput.preparedForDelivery(
                draft, action: .rewrite, toOutlook: true, insertsAtCaret: range.length == 0,
                boundaries: boundaries)
            let trailing = range.length == 0
                && boundaries?.followingLineBreakCount == 0 ? "\n" : ""
            expect(delivery == leading + (wholeLines ? split : draft) + trailing,
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

    static func openerOnlyReplyFails() {
        let state = QuickActionPanelState(action: .rewrite, original: "Rough notes",
            targetLanguage: Locale.Language(identifier: "en"))
        expect(!state.finish("I hope this email finds you well.") && state.output.isEmpty
            && state.phase == .failed(QuickActionPanelState.emptyDraftMessage),
            "a reply that cleanup empties fails instead of finishing with nothing to deliver")
        let refined = QuickActionPanelState(action: .rewrite, original: "Rough notes",
            targetLanguage: Locale.Language(identifier: "en"))
        refined.finish("Ready.")
        refined.refinementInstruction = "Shorter"
        _ = refined.beginRefinement()
        expect(!refined.finish("I hope this message finds you well.") && refined.output == "Ready."
            && refined.refinementInstruction == "Shorter" && refined.phase == .finished,
            "an emptied refinement keeps the previous draft and the request")
    }

    static func failedFirstRewriteKeepsSourceDashes() {
        let source = "The plan — as agreed — ships Friday."
        let state = QuickActionPanelState(action: .rewrite, original: source,
            targetLanguage: Locale.Language(identifier: "en"))
        state.fail("Stopped")
        state.refinementInstruction = "Make it shorter"
        expect(state.beginRefinement()?.draft == "",
            "a refinement after a failed first rewrite still has no earlier draft")
        expect(state.finish(source) && state.output == source,
            "the user's own dashes survive a typed request after a failed first rewrite")
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

    static func resumedTargetFollowsThePress() {
        let prefix = "Hi,\n\n"
        let draft = "Saved draft."
        let other = "Another paragraph."
        let body = prefix + draft + "\n\n" + other + "\n\nSignature"
        let draftRange = NSRange(location: prefix.utf16.count, length: draft.utf16.count)
        let otherRange = NSRange(
            location: (prefix + draft + "\n\n").utf16.count, length: other.utf16.count)
        let anchor = ComposerDraftAnchor(body: body, range: draftRange)
        func restored(_ range: NSRange, caret: Bool) -> NSRange? {
            ComposerDraftAnchor.restoredRange(
                in: body, anchor: anchor, selectedRange: range, insertsAtCaret: caret)
        }
        expect(restored(otherRange, caret: false) == otherRange,
            "a different selection wins over a valid saved draft boundary")
        expect(restored(NSRange(location: draftRange.location, length: draftRange.length + 1),
            caret: false) == draftRange,
            "reselecting the saved draft with its line break keeps the saved boundary")
        expect(restored(NSRange(location: draftRange.location + 3, length: 0), caret: true)
            == draftRange, "a caret inside the saved draft targets the whole draft")
        for edge in [draftRange.location, NSMaxRange(draftRange)] {
            expect(restored(NSRange(location: edge, length: 0), caret: true) == draftRange,
                "a caret at either edge of the saved draft targets the whole draft")
        }
        let outside = NSRange(location: otherRange.location + 2, length: 0)
        expect(restored(outside, caret: true) == outside,
            "a caret outside the saved draft inserts where it was pressed")
        expect(restored(outside, caret: false) == nil,
            "a selected-text press that reports only a caret outside the draft replaces nothing")

        let record = makeState().historyRecord()!
        let presses: [(NSRange, String)] = [
            (outside, "Insert"),
            (NSRange(location: draftRange.location + 3, length: 0), "Replace"),
            (otherRange, "Replace"),
        ]
        for (press, title) in presses {
            let target = restored(press, caret: press.length == 0)
            let resumeTarget = QuickActionPanelState.resumeTarget(
                savedDraft: draftRange, replacementRange: target)
            let state = QuickActionPanelState(
                restoring: record, context: nil, targetLanguage: Locale.Language(identifier: "en"),
                insertsAtCaret: resumeTarget == .insertionPoint)
            expect(state.deliveryActionTitle == title,
                "a resumed conversation names the delivery its effective target will perform")
        }

        let selected = makeState(caret: false)
        selected.finish("Saved draft.")
        expect(selected.resumeSource(.selectedText, text: other, anchor: nil),
            "a different selection requests an automatic refinement")
        expect(selected.output == other && !selected.canReplace,
            "a different selection is source text until its rewrite finishes")
    }

    static func resumedSourceDecision() {
        let saved = NSRange(location: 10, length: 5)
        let selected = NSRange(location: 20, length: 8)
        let caret = NSRange(location: 30, length: 0)
        let cases: [(NSRange?, NSRange?, QuickActionPanelState.ResumeTarget)] = [
            (saved, saved, .savedDraft),
            (saved, selected, .selectedText),
            (nil, selected, .reanchoredSelection),
            (saved, caret, .insertionPoint),
            (nil, caret, .insertionPoint),
            (saved, nil, .unavailable),
            (nil, nil, .unavailable),
            (caret, caret, .insertionPoint),
            (caret, selected, .selectedText),
        ]
        for (savedDraft, replacement, expected) in cases {
            expect(QuickActionPanelState.resumeTarget(
                savedDraft: savedDraft, replacementRange: replacement) == expected,
                "the shipped resume policy chooses the source action from the effective range")
        }
    }

    static func differentSelectionRequiresRewrite() {
        let body = "Saved draft.\n\nAnother paragraph.\n\nSignature"
        let saved = NSRange(location: 0, length: "Saved draft.".utf16.count)
        let anchor = ComposerDraftAnchor(body: body, range: saved)
        for (source, caret) in [
            ("Another paragraph.", false), ("Rough notes", false),
            ("Saved draft.", false), ("Another paragraph.", true),
        ] {
            let state = makeState(caret: caret)
            if caret {
                state.refinementInstruction = "Write a reply"
                _ = state.beginInitialRewrite()
            }
            state.finish("Saved draft.")
            state.draftAnchor = anchor
            let previous = state.conversation
            let historyID = state.historyID
            expect(state.resumeSource(.selectedText, text: source, anchor: nil),
                "a different range always requests rewriting, even when its text matches an older draft")
            expect(state.historyID == historyID && Array(state.conversation.dropLast()) == previous,
                "the selected source keeps the email's conversation")
            expect(state.conversation.last?.role == .user
                && state.conversation.last?.text.hasSuffix(source) == true,
                "the selected source is honestly attributed to the reader")
            expect(!state.canReplace && state.canRefine && state.output == source,
                "adopting source text enables refinement and keeps delivery disabled")
            expect(state.historyRecord()?.latestDraft == "Saved draft.",
                "selecting other text never saves it as a completed model draft")

            let request = state.beginRefinement()
            expect(request?.draft == source && state.isRunning && !state.canReplace,
                "the automatic refinement works on the selected text, with delivery unavailable")
            expect(request?.messages.last?.text == QuickActionPanelState.selectedRewriteInstruction,
                "the model receives the explicit rewrite request as the latest user turn")
            expect(request?.messages.contains {
                $0.role == .user && $0.text.hasSuffix(source)
            } == true, "the selected source reaches the model with the saved conversation")
            state.append("Partial reply")
            state.fail("Stopped")
            expect(state.output == source && !state.canReplace && state.canRefine,
                "a failed or stopped automatic rewrite retains its source for retry, never delivery")
            expect(state.refinementInstruction == QuickActionPanelState.selectedRewriteInstruction,
                "the automatic request returns to the field after failure")
            expect(state.draftAnchor == anchor,
                "an unsuccessful different-selection rewrite never moves the saved boundary")

            let restored = QuickActionPanelState(
                restoring: state.historyRecord()!, context: nil,
                targetLanguage: Locale.Language(identifier: "en"), insertsAtCaret: false)
            expect(restored.output == source && !restored.canReplace && restored.canRefine,
                "a saved failed selection rewrite restores the source and its delivery restriction")
            expect(restored.beginRefinement()?.draft == source,
                "retry after reopening still rewrites the selection rather than the earlier draft")
            expect(!restored.finish("I hope this email finds you well.") && !restored.canReplace,
                "an unusable automatic reply cannot enable delivery")
            _ = restored.beginRefinement()
            restored.finish("Rewritten selection.")
            expect(restored.canReplace && restored.output == "Rewritten selection.",
                "only a successful model turn makes the selection deliverable")
            expect(restored.draftAnchor == anchor,
                "generation alone keeps the saved boundary until successful delivery")
            let turns = restored.conversation.count
            expect(!restored.resumeSource(.selectedText, text: source + " ", anchor: nil)
                && restored.conversation.count == turns
                && restored.output == "Rewritten selection." && restored.canReplace,
                "pressing again on a selection already rewritten restores its draft, no new request")
        }

        let typed = makeState(caret: false)
        typed.finish("Saved draft.")
        typed.refinementInstruction = "Make it friendlier"
        expect(!typed.resumeSource(.selectedText, text: "Another paragraph.", anchor: nil)
            && typed.refinementInstruction == "Make it friendlier"
            && typed.output == "Another paragraph." && !typed.canReplace && typed.canRefine,
            "a typed request survives a different selection and waits to be sent")
        let typedRequest = typed.beginRefinement()
        expect(typedRequest?.draft == "Another paragraph."
            && typedRequest?.messages.last?.text == "Make it friendlier",
            "sending the typed request rewrites the selected text with it")
    }

    static func selectedSourceSurvivesInterruption() throws {
        let state = makeState(caret: false)
        state.finish("Earlier draft.")
        _ = state.resumeSource(.selectedText, text: "Selected source.", anchor: nil)
        _ = state.beginRefinement()
        state.append("Interrupted reply")
        let clock = Date(timeIntervalSince1970: 1_000_000)
        let data = try JSONEncoder().encode(state.historyRecord(now: clock)!)
        let record = try JSONDecoder().decode(RewriteHistoryRecord.self, from: data)
        let restored = QuickActionPanelState(
            restoring: record, context: nil,
            targetLanguage: Locale.Language(identifier: "en"), insertsAtCaret: true)
        expect(restored.output == "Selected source." && !restored.canReplace && restored.canRefine,
            "an interrupted selected-source request restores its source, never its partial output")
        expect(restored.deliveryActionTitle == "Insert" && !restored.canReplace,
            "reopening at an insertion point cannot deliver an unfinished selected-source request")
        expect(!restored.conversation.contains { $0.state == .streaming },
            "a recovered selected-source request has no abandoned streaming row")
        restored.refinementInstruction = "Make it shorter"
        let turns = restored.conversation.count
        expect(!restored.resumeSource(.selectedText, text: "Selected  source.", anchor: nil)
            && restored.refinementInstruction == "Make it shorter"
            && restored.conversation.count == turns,
            "reopening the pending selection keeps its edited request and waits for a retry")
        let retry = restored.beginRefinement()
        expect(retry?.draft == "Selected source."
            && retry?.messages.contains { $0.text.hasSuffix("Selected source.") } == true,
            "editing the retry instruction keeps the selected source in the model conversation")
        expect(retry?.messages.contains {
            $0.text == QuickActionPanelState.selectedRewriteInstruction
        } == false, "retry excludes the interrupted automatic request")
        restored.finish("Short source.")
        let finished = QuickActionPanelState(
            restoring: restored.historyRecord(now: clock)!, context: nil,
            targetLanguage: Locale.Language(identifier: "en"), insertsAtCaret: false)
        expect(finished.output == "Short source." && finished.canReplace,
            "a completed selected-source rewrite restores as an ordinary deliverable draft")

        let abandoned = QuickActionPanelState(
            restoring: record, context: nil,
            targetLanguage: Locale.Language(identifier: "en"), insertsAtCaret: false)
        expect(abandoned.resumeSource(.selectedText, text: "Other source.", anchor: nil),
            "a leftover automatic request still rewrites a new selection automatically")
        let next = abandoned.beginRefinement()
        expect(next?.draft == "Other source."
            && next?.messages.filter { $0.text.hasPrefix("Text selected in Outlook") }.count == 1
            && next?.messages.contains { $0.text.hasSuffix("Other source.") } == true,
            "only the newest selection reaches the model")
    }

    static func explicitSelectionReanchorsDraft() {
        let original = "Rough notes\n\nSignature"
        let oldAnchor = ComposerDraftAnchor(
            body: original, range: NSRange(location: 0, length: "Rough notes".utf16.count))
        let body = "New introduction\n\nRough notes\n\nChanged signature"
        let selection = NSRange(
            location: "New introduction\n\n".utf16.count, length: "Rough notes".utf16.count)
        let newAnchor = ComposerDraftAnchor(body: body, range: selection)
        for savedAnchor in [oldAnchor, nil] {
            let state = makeState(caret: false)
            state.finish("Earlier generated draft.")
            state.draftAnchor = savedAnchor
            let savedDraft = savedAnchor?.rangePreservingLineBreaks(in: body)
            let replacement = ComposerDraftAnchor.restoredRange(
                in: body, anchor: savedAnchor, selectedRange: selection, insertsAtCaret: false)
            let target = QuickActionPanelState.resumeTarget(
                savedDraft: savedDraft, replacementRange: replacement)
            expect(target == .reanchoredSelection,
                "an explicit selection recovers both a stale boundary and a missing one")
            expect(!state.resumeSource(target, text: "Rough notes", anchor: newAnchor),
                "re-anchoring manual edits does not automatically run the model")
            expect(state.draftAnchor == newAnchor && state.output == "Rough notes"
                && state.canReplace, "re-anchoring adopts the explicit selection even if it equals the original")
            expect(state.conversation.dropLast().last?.text
                == "I edited the draft in Outlook. Use this version for further changes.",
                "a recovered boundary uses the manual-edit wording")
            expect(state.historyRecord()?.draftAnchor == newAnchor
                && state.historyRecord()?.latestDraft == "Rough notes",
                "the re-anchored selection and its boundary are saved together")
            let count = state.conversation.count
            expect(!state.resumeSource(.savedDraft, text: "Rough notes", anchor: newAnchor)
                && state.conversation.count == count,
                "reopening the re-anchored selection adds neither a turn nor a model request")
        }
    }

    static func savedDraftAndCaretKeepTheirBehavior() {
        let state = makeState(caret: false)
        state.finish("Saved draft.")
        let body = "Edited draft.\n\nSignature"
        let anchor = ComposerDraftAnchor(
            body: body, range: NSRange(location: 0, length: "Edited draft.".utf16.count))
        expect(!state.resumeSource(.savedDraft, text: "Edited draft.", anchor: anchor),
            "editing the saved draft does not generate automatically")
        expect(state.output == "Edited draft." && state.draftAnchor == anchor && state.canReplace,
            "manual edits inside the saved boundary remain deliverable")
        let conversation = state.conversation
        expect(!state.resumeSource(.insertionPoint, text: "", anchor: nil)
            && state.output == "Edited draft." && state.conversation == conversation
            && state.draftAnchor == anchor, "a caret outside the draft keeps its conversation and saved boundary")
        expect(!state.resumeSource(.unavailable, text: nil, anchor: nil)
            && !state.canReplace && state.replacementIssue != nil,
            "an unavailable selection disables delivery and asks the reader to capture afresh")
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

        for header in ["De : Jean Dupont", "De\u{a0}: Jean Dupont", "Le jeudi, Jean a écrit\u{a0}:"] {
            let french = QuickActionContext.outlook(
                body: "Signature\n" + header + "\nNouvelle question",
                selectedRange: NSRange(location: 0, length: 0), recipient: nil, subject: nil)
            expect(french?.recentThread?.contains("Nouvelle question") == true
                && french?.recentThread?.contains("Signature") == false,
                "a French header with a space before its colon begins the newest message")
        }
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

    static func separateRepliesKeepSeparateConversations() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComposerSeparateReplies-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RewriteHistoryStore(directory: directory, key: { historyKey })
        let quoted = "From: Alice\nCan we move the launch?"
        func context(
            _ recipient: String, editor: String, newer: String = ""
        ) -> QuickActionContext {
            QuickActionContext(recipient: recipient, subject: "RE: Launch",
                recentThread: newer + quoted, documentIdentity: editor)
        }
        func conversation(
            _ context: QuickActionContext, draft: String, turns: Int
        ) -> QuickActionPanelState {
            let state = QuickActionPanelState(
                action: .rewrite, original: "", context: context,
                targetLanguage: Locale.Language(identifier: "en"), awaitsWritingInstruction: true)
            for turn in 0..<turns {
                state.refinementInstruction = "Request \(turn)"
                if turn == 0 { _ = state.beginInitialRewrite() } else { _ = state.beginRefinement() }
                state.finish("\(draft) \(turn)")
            }
            return state
        }
        let privateContext = context("Alice <alice@example.com>", editor: "editor-private")
        let privateReply = conversation(privateContext, draft: "Private", turns: 2)
        expect(store.save(privateReply.historyRecord()!), "the private reply is saved")
        expect(privateReply.historyRecord()?.editorIdentity == "editor-private",
            "a saved conversation remembers its Outlook editor")

        let allContext = context(
            "Alice <alice@example.com>; Team <team@example.com>", editor: "editor-all")
        expect(store.resumableRecord(selection: "", context: allContext) == nil,
            "a reply-all to the same message does not inherit the private reply")
        let replyAll = conversation(allContext, draft: "Everyone", turns: 1)
        expect(store.save(replyAll.historyRecord()!), "the reply-all is saved separately")
        expect(store.resumableRecord(selection: "", context: privateContext)?.id == privateReply.historyID
            && store.resumableRecord(selection: "", context: allContext)?.id == replyAll.historyID,
            "each open reply editor keeps its own conversation")
        expect(store.records.count == 2, "neither reply's conversation is deleted")

        let reopened = context("Alice <alice@example.com>", editor: "editor-reopened")
        expect(store.resumableRecord(selection: "", context: reopened)?.id == privateReply.historyID,
            "a reopened editor for the same people resumes their conversation")

        let newerQuote = "From: Alice\nAny update?\n"
        let newerAll = context("Alice <alice@example.com>; Team <team@example.com>",
            editor: "editor-newer-all", newer: newerQuote)
        expect(store.resumableRecord(selection: "", context: newerAll)?.id == replyAll.historyID,
            "a newer reply-all continues the reply-all, not the longer private conversation")
        let newer = context("Alice <alice@example.com>", editor: "editor-newer", newer: newerQuote)
        expect(store.resumableRecord(selection: "", context: newer)?.id == privateReply.historyID,
            "a newer private reply continues the private conversation")
        func recipient(of id: UUID) -> String? { store.records.first(where: { $0.id == id })?.recipient }
        expect(recipient(of: privateReply.historyID) == "Alice <alice@example.com>"
            && recipient(of: replyAll.historyID) == "Alice <alice@example.com>; Team <team@example.com>",
            "resuming never hands one reply's recipients to the other")
        expect(Set(store.records.map(\.id)) == [privateReply.historyID, replyAll.historyID],
            "a match through a shared quote never deletes another reply's conversation")

        let outsider = context(
            "Bob <bob@example.com>", editor: "editor-outsider", newer: newerQuote)
        expect(store.resumableRecord(selection: "", context: outsider) == nil,
            "a reply to entirely different people never continues either conversation")
    }

    static func historyFollowsEditorAndRecipients() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComposerEditorHistory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RewriteHistoryStore(directory: directory, key: { historyKey })
        func conversation(_ context: QuickActionContext, draft: String) -> QuickActionPanelState {
            let state = QuickActionPanelState(
                action: .rewrite, original: "", context: context,
                targetLanguage: Locale.Language(identifier: "en"), awaitsWritingInstruction: true)
            state.refinementInstruction = "Write it"
            _ = state.beginInitialRewrite()
            state.finish(draft)
            return state
        }

        let alice = QuickActionContext(recipient: "Alice <alice@example.com>", subject: "Plans",
            recentThread: nil, documentIdentity: "outlook-new-email")
        let aliceEmail = conversation(alice, draft: "Here are the plans.")
        expect(store.save(aliceEmail.historyRecord()!), "the new email to Alice is saved")
        let renamed = QuickActionContext(recipient: "Alice <alice@example.com>", subject: "Updated plans",
            recentThread: nil, documentIdentity: "outlook-new-email")
        expect(store.resumableRecord(selection: "", context: renamed)?.id == aliceEmail.historyID,
            "a new email keeps its conversation after its subject changes")
        let withCc = QuickActionContext(
            recipient: "Alice <alice@example.com>; Carol <carol@example.com>", subject: "Updated plans",
            recentThread: nil, documentIdentity: "outlook-new-email")
        expect(store.resumableRecord(selection: "", context: withCc)?.id == aliceEmail.historyID,
            "adding a Cc to a new email keeps its conversation")
        let reusedEditor = QuickActionContext(recipient: "Bob <bob@example.com>", subject: "Updated plans",
            recentThread: nil, documentIdentity: "outlook-new-email")
        expect(store.resumableRecord(selection: "", context: reusedEditor) == nil,
            "a reused editor addressed to someone else never inherits the conversation")
        let unaddressed = QuickActionContext(recipient: nil, subject: nil,
            recentThread: nil, documentIdentity: "outlook-new-email")
        expect(store.resumableRecord(selection: "", context: unaddressed)?.id == aliceEmail.historyID,
            "an unread recipient list never splits a new email's conversation")

        let quoted = "From: Dana\nCan you send the numbers?"
        let reply = QuickActionContext(recipient: "Dana <dana@example.com>", subject: "RE: Numbers",
            recentThread: quoted, documentIdentity: "editor-reply")
        let replyState = conversation(reply, draft: "Here are the numbers.")
        expect(store.save(replyState.historyRecord()!), "the reply is saved")
        let reopenedWithCc = QuickActionContext(
            recipient: "Dana <dana@example.com>; Erin <erin@example.com>", subject: "RE: Numbers",
            recentThread: quoted, documentIdentity: "editor-reopened")
        expect(store.resumableRecord(selection: "", context: reopenedWithCc) == nil,
            "another editor on the same snapshot with more people starts its own conversation")
        expect(store.resumableRecord(selection: "Here are the numbers.", context: reopenedWithCc)?.id
            == replyState.historyID,
            "a reopened draft that gained a Cc resumes when its draft is selected")
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
        let inFlight = directory.appendingPathComponent(".rewrite-history-\(UUID().uuidString)")
        try sealed.write(to: staged)
        try sealed.write(to: inFlight)
        try FileManager.default.setAttributes(
            [.modificationDate: timestamp.addingTimeInterval(-2 * 60 * 60)], ofItemAtPath: staged.path)
        try FileManager.default.setAttributes(
            [.modificationDate: timestamp], ofItemAtPath: inFlight.path)
        let store = RewriteHistoryStore(directory: directory, key: { historyKey }, now: { timestamp })
        store.load()
        expect(!FileManager.default.fileExists(atPath: staged.path),
            "a staged write a crash left behind is removed on load")
        expect(FileManager.default.fileExists(atPath: inFlight.path),
            "a fresh staged write may be another instance's save and is kept")
        try FileManager.default.removeItem(at: inFlight)
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
        try FileManager.default.removeItem(at: file)
        expect(unauthenticated.save(record),
            "removing the unreadable file by hand unblocks saving without a relaunch")

        try before.write(to: file)
        let recreatedKey = SymmetricKey(size: .bits256)
        let recreated = RewriteHistoryStore(
            directory: directory, keyLookup: { (recreatedKey, true) }, now: { timestamp })
        recreated.load()
        expect(!FileManager.default.fileExists(atPath: file.path) && recreated.save(record),
            "a key Keychain just created cannot open older history, so that file stops blocking saves")
        let kept = try Data(contentsOf: file)
        let existing = RewriteHistoryStore(
            directory: directory, keyLookup: { (wrongKey, false) }, now: { timestamp })
        existing.load()
        expect((try? Data(contentsOf: file)) == kept,
            "an existing key that cannot open the file leaves it intact")
    }

    static func historyKeyIsLazyAndWritesArePrivate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComposerPrivateHistory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = directory.appendingPathComponent("rewrite-history.json")
        try Data("obsolete private draft".utf8).write(to: legacy)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        var keyReads: Int { reads.withLock { $0 } }
        let store = RewriteHistoryStore(directory: directory, key: {
            reads.withLock { $0 += 1 }
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

    /// A Keychain prompt for a rebuilt app may stay open for minutes; the main actor must not wait.
    static func historyKeyWaitsOffTheMainActor() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComposerKeychainWait-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = RewriteHistoryRecord(
            id: UUID(), createdAt: Date(), updatedAt: Date(), subject: nil, recipient: nil,
            original: "Saved draft", messages: [])
        expect(RewriteHistoryStore(directory: directory, key: { historyKey }).save(record),
            "history exists before the relaunch")
        let answer = DispatchSemaphore(value: 0)
        let readOnMain = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let store = RewriteHistoryStore(directory: directory, key: {
            readOnMain.withLock { $0 = Thread.isMainThread }
            // A regression that asks on the main actor times out instead of hanging the suite.
            _ = answer.wait(timeout: .now() + 2)
            return historyKey
        })
        store.tidy()
        expect(readOnMain.withLock { $0 } == nil, "launch never asks Keychain, even with history saved")
        Task { await store.loadOnFirstUse() }
        spin { readOnMain.withLock { $0 } != nil }
        expect(readOnMain.withLock { $0 } == false,
            "Composer's first open asks Keychain away from the main thread")
        expect(store.records.isEmpty, "history reads as empty while Keychain is still asking")
        var changed = record
        changed.pendingInstruction = "Must not land"
        expect(!store.save(changed), "a save fails rather than wait while Keychain is still asking")
        answer.signal()
        spin { !store.records.isEmpty }
        expect(store.records == [record], "history opens once Keychain answers")
        expect(store.save(changed), "saves work once Keychain answers")

        try FileManager.default.removeItem(at: directory)
        let reads = OSAllocatedUnfairLock(initialState: [Bool]())
        let fresh = RewriteHistoryStore(directory: directory, key: {
            reads.withLock { $0.append(Thread.isMainThread) }
            return historyKey
        })
        fresh.tidy()
        Task { await fresh.loadOnFirstUse() }
        Task { await fresh.loadOnFirstUse() }
        spin { !reads.withLock { $0 }.isEmpty }
        spin { fresh.save(record) }
        expect(reads.withLock { $0 } == [false],
            "opening Composer twice asks Keychain once, away from the main thread, for the first save")

        // A prompt nobody saw times out with no key; the next Composer open asks again.
        let answers = OSAllocatedUnfairLock(initialState: [SymmetricKey?]([nil, historyKey]))
        let asked = OSAllocatedUnfairLock(initialState: 0)
        let missed = RewriteHistoryStore(directory: directory, key: {
            asked.withLock { $0 += 1 }
            return answers.withLock { $0.isEmpty ? historyKey : $0.removeFirst() }
        })
        var done = false
        Task { await missed.loadOnFirstUse(); done = true }
        spin { done }
        expect(missed.records.isEmpty && !missed.save(changed),
            "without an answer from Keychain history stays unread and unwritten")
        done = false
        Task { await missed.loadOnFirstUse(); done = true }
        spin { done }
        expect(missed.records == [record], "the next Composer open asks Keychain again and reads history")
        done = false
        Task { await missed.loadOnFirstUse(); done = true }
        spin { done }
        expect(asked.withLock { $0 } == 2, "once Keychain has supplied the key it is not asked again")
    }

    /// Runs the main actor's queue until `done`, for at most two seconds.
    private static func spin(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !done(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
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
