import Foundation
import Observation

/// Owned by the controller, not the view, so a reply keeps arriving while SwiftUI re-renders.
@MainActor
@Observable
final class QuickActionPanelState {
    static let contextOnlyInstruction =
        "Draft an appropriate response based only on the email context. Do not invent facts, "
        + "commitments, decisions or completed actions."

    enum Accessory: Equatable { case context, audience, model, reasoning, history(UUID) }
    var accessory: Accessory?
    var accessorySelection = 0
    var viewedHistoryID: UUID?

    enum Phase: Equatable {
        case awaitingInstruction
        case running
        case finished
        case failed(String)
        /// The pair is supported but not downloaded; the reader fetches it in System Settings.
        case needsLanguageDownload
    }

    let action: QuickAction
    private(set) var original: String
    let context: QuickActionContext?
    let originalIsWritingInstruction: Bool
    let insertsAtCaret: Bool
    let historyID: UUID
    let createdAt: Date
    private let historySubject: String?
    private let historyRecipient: String?
    private let historyContextIdentity: String?
    private let historyContextFingerprints: [String]
    private let historyEditorIdentity: String?
    private(set) var output = ""
    private(set) var phase: Phase = .running
    private(set) var conversation: [RewriteConversationMessage] = []
    var refinementInstruction = ""
    var targetLanguage: Locale.Language
    var draftAnchor: ComposerDraftAnchor?
    var replacementIssue: String?
    var audienceOverride: ComposerAudience?

    @ObservationIgnored private var cachedDiff: [TextDiffEngine.Chunk]?
    @ObservationIgnored private var previousOutput: String?
    @ObservationIgnored private var submittedInstruction: String?

    var diff: [TextDiffEngine.Chunk] {
        guard action.showsDiff, phase == .finished else { return [] }
        if let cachedDiff { return cachedDiff }
        let chunks = TextDiffEngine.diff(original: original, modified: output)
        cachedDiff = chunks
        return chunks
    }

    var isRunning: Bool { phase == .running }

    var isAwaitingInstruction: Bool { phase == .awaitingInstruction }

    var canReplace: Bool { phase == .finished && !output.isEmpty && replacementIssue == nil }

    /// A replacement issue asks the reader to reopen, so pressing again must capture afresh.
    var reopensFromSource: Bool { !isRunning && replacementIssue == nil }

    /// A saved conversation on screen is view and copy only, so it hides the active one's controls.
    var isViewingActive: Bool { viewedHistoryID == nil || viewedHistoryID == historyID }

    /// Without a known range, or with different text there, the same field is a new request.
    func reopensFromField(
        selection: NSRange?, pressedSelection: NSRange?, characterCount: Int?,
        pressedCharacterCount: Int?, selectedText: () -> String?
    ) -> Bool {
        guard reopensFromSource, let selection, selection == pressedSelection else { return false }
        if insertsAtCaret {
            return selection.length == 0 && characterCount != nil
                && characterCount == pressedCharacterCount
        }
        guard selection.length > 0, let text = selectedText() else { return false }
        return Self.collapsingWhitespace(text) == Self.collapsingWhitespace(original)
    }

    private static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    var deliveryActionTitle: String {
        action == .rewrite && insertsAtCaret ? "Insert" : "Replace"
    }

    func canDeliver(isViewingActive: Bool) -> Bool {
        isViewingActive && canReplace
    }

    var needsInitialRequest: Bool { isAwaitingInstruction || isInitialFailure }

    private var isInitialFailure: Bool {
        if case .failed = phase { return action == .rewrite && output.isEmpty }
        return false
    }

    var canRefine: Bool {
        action == .rewrite && (phase == .finished || needsInitialRequest)
            && (hasInstruction || canDraftFromContext || retriesOriginalRequest)
    }

    /// A selected draft that never got a reply is its own request, so retrying needs no words.
    var retriesOriginalRequest: Bool {
        isInitialFailure && !originalIsWritingInstruction && !hasInstruction
    }

    private var hasInstruction: Bool {
        !refinementInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canDraftFromContext: Bool {
        originalIsWritingInstruction && needsInitialRequest && context?.recentThread != nil
    }

    init(
        action: QuickAction, original: String, context: QuickActionContext? = nil,
        targetLanguage: Locale.Language, historyID: UUID = UUID(), createdAt: Date = Date(),
        awaitsWritingInstruction: Bool = false
    ) {
        self.action = action
        self.original = original
        self.context = context
        originalIsWritingInstruction = awaitsWritingInstruction
        insertsAtCaret = awaitsWritingInstruction
        self.targetLanguage = targetLanguage
        self.historyID = historyID
        self.createdAt = createdAt
        historySubject = context?.subject
        historyRecipient = context?.recipient
        historyContextIdentity = context?.historyIdentity
        historyContextFingerprints = context?.historyFingerprints ?? []
        historyEditorIdentity = context?.documentIdentity
        if awaitsWritingInstruction { phase = .awaitingInstruction }
    }

    init(
        restoring record: RewriteHistoryRecord, context: QuickActionContext?,
        targetLanguage: Locale.Language, insertsAtCaret: Bool
    ) {
        let restoredOutput = record.latestDraft ?? ""
        action = .rewrite
        original = record.original
        self.context = context
        originalIsWritingInstruction = record.originalIsWritingInstruction == true
        self.insertsAtCaret = insertsAtCaret
        historyID = record.id
        createdAt = record.createdAt
        historySubject = context?.subject ?? record.subject
        historyRecipient = context?.recipient ?? record.recipient
        historyContextIdentity = context?.historyIdentity ?? record.contextIdentity
        historyContextFingerprints = context?.historyFingerprints ?? record.contextFingerprints ?? []
        historyEditorIdentity = context?.documentIdentity ?? record.editorIdentity
        output = restoredOutput
        conversation = record.messages
        refinementInstruction = record.pendingInstruction ?? ""
        self.targetLanguage = targetLanguage
        draftAnchor = record.draftAnchor
        audienceOverride = record.audienceOverride
        for index in conversation.indices where conversation[index].state == .streaming {
            conversation[index].state = .failed
            conversation[index].text = "Generation was interrupted. Send your request again to retry."
            if index > 0, conversation[index - 1].role == .user {
                conversation[index - 1].state = .failed
            }
        }
        phase = Self.restoredPhase(
            output: restoredOutput, conversation: conversation,
            awaitsInstruction: originalIsWritingInstruction)
    }

    /// A selected draft that never got a reply has no instruction to await, only one to retry.
    private static func restoredPhase(
        output: String, conversation: [RewriteConversationMessage], awaitsInstruction: Bool
    ) -> Phase {
        guard output.isEmpty else { return .finished }
        guard !awaitsInstruction else { return .awaitingInstruction }
        let failure = conversation.last { $0.role == .assistant && $0.state == .failed }
        return .failed(failure?.text ?? "No draft was generated. Retry to send the text again.")
    }

    func adoptSourceDraft(_ text: String, selectedElsewhere: Bool = false) {
        let normalized = Self.collapsingWhitespace
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            normalized(text) != normalized(output),
            originalIsWritingInstruction || normalized(text) != normalized(original)
        else { return }
        let request = selectedElsewhere
            ? "I selected other text in Outlook. Use this text for further changes."
            : "I edited the draft in Outlook. Use this version for further changes."
        conversation.append(RewriteConversationMessage(role: .user, text: request, state: .complete))
        conversation.append(RewriteConversationMessage(role: .assistant, text: text, state: .complete))
        output = text
        phase = .finished
    }

    func append(_ delta: String) {
        guard isRunning else { return }
        output += delta
        guard action == .rewrite else { return }
        if conversation.last?.role != .assistant
            || conversation.last?.state != .streaming
        {
            conversation.append(
                RewriteConversationMessage(role: .assistant, text: "", state: .streaming))
        }
        conversation[conversation.count - 1].text += delta
    }

    func restart() {
        output = ""
        phase = .running
        previousOutput = nil
        cachedDiff = nil
    }

    func beginInitialRewrite() -> String? {
        guard needsInitialRequest, canRefine else { return nil }
        let typedInstruction = refinementInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let instruction = typedInstruction.isEmpty ? Self.contextOnlyInstruction : typedInstruction
        if originalIsWritingInstruction { original = instruction }
        submittedInstruction = instruction
        conversation.append(
            RewriteConversationMessage(role: .user, text: instruction, state: .complete))
        conversation.append(
            RewriteConversationMessage(role: .assistant, text: "", state: .streaming))
        output = ""
        phase = .running
        refinementInstruction = ""
        return instruction
    }

    func beginRefinement() -> (draft: String, messages: [AIMessage])? {
        guard canRefine else { return nil }
        let instruction = refinementInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        submittedInstruction = instruction
        previousOutput = output
        conversation.append(
            RewriteConversationMessage(role: .user, text: instruction, state: .complete))
        conversation.append(
            RewriteConversationMessage(role: .assistant, text: "", state: .streaming))
        output = ""
        phase = .running
        refinementInstruction = ""
        return (previousOutput ?? "", requestMessages)
    }

    static let emptyDraftMessage = "The model returned no usable draft. Retry to send the text again."

    /// Cleanup can strip a reply down to nothing, which must fail rather than finish empty.
    @discardableResult
    func finish(_ text: String) -> Bool {
        let completed = action == .rewrite
            ? QuickActionOutput.composerDraft(
                in: text, source: previousOutput ?? (originalIsWritingInstruction ? "" : original))
            : text
        if action == .rewrite, completed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fail(Self.emptyDraftMessage)
            return false
        }
        output = completed
        phase = .finished
        cachedDiff = nil
        refinementInstruction = ""
        previousOutput = nil
        submittedInstruction = nil
        guard action == .rewrite else { return true }
        if conversation.last?.role == .assistant
            && conversation.last?.state == .streaming
        {
            conversation[conversation.count - 1].text = completed
            conversation[conversation.count - 1].state = .complete
        } else {
            conversation.append(
                RewriteConversationMessage(role: .assistant, text: completed, state: .complete))
        }
        return true
    }

    func fail(_ message: String) {
        output = previousOutput ?? ""
        previousOutput = nil
        phase = output.isEmpty ? .failed(message) : .finished
        cachedDiff = nil
        refinementInstruction = submittedInstruction ?? refinementInstruction
        submittedInstruction = nil
        guard action == .rewrite else { return }
        if refinementInstruction == Self.contextOnlyInstruction { refinementInstruction = "" }
        if conversation.last?.role == .assistant && conversation.last?.state == .streaming {
            let assistant = conversation.count - 1
            conversation[assistant].text = message
            conversation[assistant].state = .failed
            if assistant > 0, conversation[assistant - 1].role == .user {
                conversation[assistant - 1].state = .failed
            }
        } else {
            conversation.append(RewriteConversationMessage(
                role: .assistant, text: message, state: .failed))
        }
    }

    func requireLanguageDownload() {
        phase = .needsLanguageDownload
    }

    func composerAudience(internalDomains: String) -> ComposerAudience {
        audienceOverride ?? detectedComposerAudience(internalDomains: internalDomains)
    }

    func detectedComposerAudience(internalDomains: String) -> ComposerAudience {
        ComposerAudience.detected(
            recipient: context?.recipient ?? historyRecipient,
            internalDomains: internalDomains)
    }

    private var requestMessages: [AIMessage] {
        let complete = conversation.filter { $0.state == .complete }
        let requestConversation =
            originalIsWritingInstruction && complete.first?.role == .user
                && complete.first?.text == original
            ? Array(complete.dropFirst()) : complete
        return requestConversation.map { message in
            return AIMessage(
                role: message.role == .user ? .user : .assistant, text: message.text)
        }
    }

    func historyRecord(now: Date = Date()) -> RewriteHistoryRecord? {
        guard action == .rewrite else { return nil }
        return RewriteHistoryRecord(
            id: historyID, createdAt: createdAt, updatedAt: now,
            subject: historySubject, recipient: historyRecipient,
            contextIdentity: historyContextIdentity,
            contextFingerprints: historyContextFingerprints,
            editorIdentity: historyEditorIdentity, original: original,
            messages: conversation,
            pendingInstruction: submittedInstruction
                ?? (refinementInstruction.isEmpty ? nil : refinementInstruction),
            originalIsWritingInstruction: originalIsWritingInstruction,
            draftAnchor: draftAnchor,
            audienceOverride: audienceOverride)
    }
}
