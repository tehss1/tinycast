import Foundation
import Observation

/// Owned by the controller, not the view, so a reply keeps arriving while SwiftUI re-renders.
@MainActor
@Observable
final class QuickActionPanelState {
    enum Accessory { case context, audience, model, reasoning }
    var accessory: Accessory?
    var accessorySelection = 0

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
            && !refinementInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        output = restoredOutput
        phase = restoredOutput.isEmpty ? .awaitingInstruction : .finished
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
    }

    func adoptSourceDraft(_ text: String) {
        let normalized: (String) -> String = {
            $0.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            normalized(text) != normalized(output),
            originalIsWritingInstruction || normalized(text) != normalized(original)
        else { return }
        conversation.append(RewriteConversationMessage(
            role: .user, text: "I edited the draft in Outlook. Use this version for further changes.",
            state: .complete))
        conversation.append(RewriteConversationMessage(role: .assistant, text: text, state: .complete))
        output = text
        phase = .finished
        cachedDiff = nil
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
        let instruction = refinementInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if originalIsWritingInstruction { original = instruction }
        submittedInstruction = instruction
        conversation.append(
            RewriteConversationMessage(role: .user, text: instruction, state: .complete))
        conversation.append(
            RewriteConversationMessage(role: .assistant, text: "", state: .streaming))
        output = ""
        phase = .running
        refinementInstruction = ""
        cachedDiff = nil
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
        cachedDiff = nil
        return (previousOutput ?? "", requestMessages)
    }

    func finish(_ text: String) {
        let completed = action == .rewrite ? QuickActionOutput.composerBody(in: text) : text
        output = completed
        phase = .finished
        refinementInstruction = ""
        previousOutput = nil
        submittedInstruction = nil
        guard action == .rewrite else { return }
        if conversation.last?.role == .assistant
            && conversation.last?.state == .streaming
        {
            conversation[conversation.count - 1].text = completed
            conversation[conversation.count - 1].state = .complete
        } else {
            conversation.append(
                RewriteConversationMessage(role: .assistant, text: completed, state: .complete))
        }
    }

    func fail(_ message: String) {
        output = previousOutput ?? ""
        previousOutput = nil
        phase = output.isEmpty ? .failed(message) : .finished
        cachedDiff = nil
        refinementInstruction = submittedInstruction ?? refinementInstruction
        submittedInstruction = nil
        guard action == .rewrite else { return }
        if refinementInstruction.isEmpty, output.isEmpty {
            refinementInstruction = originalIsWritingInstruction ? original : "Try again."
        }
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
            contextFingerprints: historyContextFingerprints, original: original,
            messages: conversation,
            pendingInstruction: submittedInstruction
                ?? (refinementInstruction.isEmpty ? nil : refinementInstruction),
            originalIsWritingInstruction: originalIsWritingInstruction,
            draftAnchor: draftAnchor,
            audienceOverride: audienceOverride)
    }
}
