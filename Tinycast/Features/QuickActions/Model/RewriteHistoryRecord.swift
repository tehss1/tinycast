import Foundation

struct RewriteHistoryRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    let subject: String?
    let recipient: String?
    let contextIdentity: String?
    var contextFingerprints: [String]?
    /// Optional so history written before per-editor matching still decodes.
    let editorIdentity: String?
    let original: String
    var messages: [RewriteConversationMessage]
    var pendingInstruction: String?
    /// Optional so history written before caret-first Rewrite still decodes.
    let originalIsWritingInstruction: Bool?
    var draftAnchor: ComposerDraftAnchor?
    var screenshotAttached: Bool?
    var audienceOverride: ComposerAudience?

    init(
        id: UUID, createdAt: Date, updatedAt: Date, subject: String?, recipient: String?,
        contextIdentity: String? = nil, contextFingerprints: [String]? = nil,
        editorIdentity: String? = nil, original: String,
        messages: [RewriteConversationMessage], pendingInstruction: String? = nil,
        originalIsWritingInstruction: Bool? = nil, draftAnchor: ComposerDraftAnchor? = nil,
        audienceOverride: ComposerAudience? = nil, screenshotAttached: Bool? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.subject = subject
        self.recipient = recipient
        self.contextIdentity = contextIdentity
        self.contextFingerprints = contextFingerprints
        self.editorIdentity = editorIdentity
        self.original = original
        self.messages = messages
        self.pendingInstruction = pendingInstruction
        self.originalIsWritingInstruction = originalIsWritingInstruction
        self.draftAnchor = draftAnchor
        self.screenshotAttached = screenshotAttached
        self.audienceOverride = audienceOverride
    }

    var title: String {
        if let subject, !subject.isEmpty { return subject }
        if let recipient, !recipient.isEmpty { return recipient }
        let compact = original.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return compact.isEmpty ? "Untitled email" : String(compact.prefix(72))
    }

    static func displaySubject(_ subject: String) -> String {
        let stripped = subject.replacingOccurrences(
            of: #"^(?:(?:re|fwd?)\s*:\s+)+"#, with: "",
            options: [.regularExpression, .caseInsensitive])
        return stripped.isEmpty ? subject : stripped
    }

    var preview: String {
        guard let text = latestDraft else { return "" }
        return String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(96))
    }

    var latestDraft: String? {
        messages.last(where: {
            $0.role == .assistant && $0.state == .complete && !$0.text.isEmpty
        })?.text
    }
}
