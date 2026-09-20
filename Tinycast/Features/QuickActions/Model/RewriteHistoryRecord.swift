import Foundation

struct RewriteHistoryRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    let subject: String?
    let recipient: String?
    let contextIdentity: String?
    var contextFingerprints: [String]?
    let original: String
    var messages: [RewriteConversationMessage]
    var pendingInstruction: String?
    /// Optional so history written before caret-first Rewrite still decodes.
    let originalIsWritingInstruction: Bool?
    var draftAnchor: ComposerDraftAnchor?
    var audienceOverride: ComposerAudience?

    init(
        id: UUID, createdAt: Date, updatedAt: Date, subject: String?, recipient: String?,
        contextIdentity: String? = nil, contextFingerprints: [String]? = nil, original: String,
        messages: [RewriteConversationMessage], pendingInstruction: String? = nil,
        originalIsWritingInstruction: Bool? = nil, draftAnchor: ComposerDraftAnchor? = nil,
        audienceOverride: ComposerAudience? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.subject = subject
        self.recipient = recipient
        self.contextIdentity = contextIdentity
        self.contextFingerprints = contextFingerprints
        self.original = original
        self.messages = messages
        self.pendingInstruction = pendingInstruction
        self.originalIsWritingInstruction = originalIsWritingInstruction
        self.draftAnchor = draftAnchor
        self.audienceOverride = audienceOverride
    }

    var title: String {
        if let subject, !subject.isEmpty { return subject }
        if let recipient, !recipient.isEmpty { return recipient }
        let compact = original.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return compact.isEmpty ? "Untitled email" : String(compact.prefix(72))
    }

    var preview: String {
        guard let text = messages.last(where: {
            $0.role == .assistant && $0.state == .complete && !$0.text.isEmpty
        })?.text else { return "" }
        let body = QuickActionOutput.composerBody(in: text)
        return String(body.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(96))
    }

    var latestDraft: String? {
        guard let text = messages.last(where: {
            $0.role == .assistant && $0.state == .complete && !$0.text.isEmpty
        })?.text else { return nil }
        return QuickActionOutput.composerBody(in: text)
    }
}
