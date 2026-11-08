import Foundation

enum ConversationNotebookSection: Hashable { case notes, tasks }

struct ConversationNotebookContext: Identifiable, Equatable {
    var account: String
    var conversationID: String
    var name: String
    var section: ConversationNotebookSection = .notes
    var showCompleted = false
    var id: String { account + ":" + conversationID }
}

struct ConversationTodo: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var dueAt: Date?
    var completedAt: Date?
    var deletedAt: Date?
    var createdAt = Date.now
    var updatedAt = Date.now
    var isCompleted: Bool { completedAt != nil }
    var isOverdue: Bool { !isCompleted && deletedAt == nil && dueAt.map { $0 < .now } == true }

    func validated() throws -> Self {
        var value = self
        value.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.title.isEmpty, value.title.count <= 300, !value.title.contains("\0") else { throw PluginError.message("Tên việc cần làm từ 1 đến 300 ký tự.") }
        return value
    }
}

struct ConversationNotebook: Codable, Equatable, Identifiable {
    var account: String
    var conversationID: String
    var note = ""
    var todos: [ConversationTodo] = []
    var updatedAt = Date.now
    var id: String { account + ":" + conversationID }
    var pendingCount: Int { todos.filter { $0.deletedAt == nil && !$0.isCompleted }.count }
    func tasks(showCompleted: Bool, deleted: Bool = false) -> [ConversationTodo] {
        todos.filter { ($0.deletedAt != nil) == deleted && (deleted || showCompleted || !$0.isCompleted) }.sorted {
            if $0.isCompleted != $1.isCompleted { return !$0.isCompleted }
            let left = $0.dueAt ?? .distantFuture, right = $1.dueAt ?? .distantFuture
            if left != right { return left < right }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}
