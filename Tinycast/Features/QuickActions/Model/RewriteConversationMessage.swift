import Foundation

struct RewriteConversationMessage: Identifiable, Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    enum State: String, Codable, Sendable {
        case streaming
        case complete
        case failed
    }

    let id: UUID
    let role: Role
    var text: String
    var state: State

    init(
        id: UUID = UUID(), role: Role, text: String, state: State
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.state = state
    }
}
