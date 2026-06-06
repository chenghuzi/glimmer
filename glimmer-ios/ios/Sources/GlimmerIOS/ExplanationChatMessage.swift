import Foundation

enum ExplanationChatRole: Equatable {
    case user
    case assistant
}

struct ExplanationChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: ExplanationChatRole
    let text: String
    let isError: Bool

    init(id: UUID = UUID(), role: ExplanationChatRole, text: String, isError: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.isError = isError
    }
}
