import Testing
import Foundation
@testable import Olaz

@Suite @MainActor struct ConversationNotebookTests {
    @Test func notesAndTasksAreScopedToBothAccountAndConversation() throws {
        let store = WorkStore(url: nil)
        try store.setNote("Ghi chú khách A", account: "a", conversationID: "chat1")
        try store.setNote("Ghi chú chat 2", account: "a", conversationID: "chat2")
        try store.setNote("Ghi chú tài khoản B", account: "b", conversationID: "chat1")
        let todo = ConversationTodo(title: "Gọi lại khách")
        try store.saveTask(todo, account: "a", conversationID: "chat1")
        try store.completeTask(todo.id, completed: true, account: "b", conversationID: "chat1")
        try store.removeTask(todo.id, account: "a", conversationID: "chat2")
        #expect(store.notebook(account: "a", conversationID: "chat1").note == "Ghi chú khách A")
        #expect(store.notebook(account: "a", conversationID: "chat1").pendingCount == 1)
        #expect(store.notebook(account: "a", conversationID: "chat2").todos.isEmpty)
        #expect(store.notebook(account: "b", conversationID: "chat1").note == "Ghi chú tài khoản B")
        #expect(store.notebook(account: "b", conversationID: "chat1").todos.isEmpty)
    }
    @Test func editsCompletionAndRecoverableRemovalKeepOtherFields() throws {
        let store = WorkStore(url: nil)
        var task = ConversationTodo(title: "  Chuẩn bị báo giá  ", dueAt: Date(timeIntervalSince1970: 1000))
        try store.saveTask(task, account: "a", conversationID: "c")
        task.title = "Gửi báo giá đã duyệt"; try store.saveTask(task, account: "a", conversationID: "c")
        try store.completeTask(task.id, completed: true, account: "a", conversationID: "c")
        let completed = try #require(store.notebook(account: "a", conversationID: "c").todos.first)
        #expect(completed.isCompleted && completed.dueAt == task.dueAt && completed.title == task.title)
        #expect(store.notebook(account: "a", conversationID: "c").tasks(showCompleted: false).isEmpty)
        try store.removeTask(task.id, account: "a", conversationID: "c")
        #expect(store.notebook(account: "a", conversationID: "c").tasks(showCompleted: true).isEmpty)
        #expect(store.notebook(account: "a", conversationID: "c").tasks(showCompleted: true, deleted: true).count == 1)
        try store.restoreTask(task.id, account: "a", conversationID: "c")
        try store.completeTask(task.id, completed: false, account: "a", conversationID: "c")
        let restored = try #require(store.notebook(account: "a", conversationID: "c").todos.first)
        #expect(restored.deletedAt == nil && restored.completedAt == nil && restored.createdAt == task.createdAt)
    }
    @Test func sortPrioritizesIncompleteTasksAndEarliestDueDate() {
        let early = ConversationTodo(title: "Đến hạn sớm", dueAt: Date(timeIntervalSince1970: 1000))
        let later = ConversationTodo(title: "Đến hạn sau", dueAt: Date(timeIntervalSince1970: 2000))
        let noDue = ConversationTodo(title: "Không có hạn")
        let completed = ConversationTodo(title: "Đã hoàn thành", dueAt: Date(timeIntervalSince1970: 500), completedAt: .now)
        let deleted = ConversationTodo(title: "Đã gỡ", deletedAt: .now)
        let book = ConversationNotebook(account: "a", conversationID: "c", todos: [completed, noDue, later, deleted, early])
        #expect(book.tasks(showCompleted: false).map(\.id) == [early.id, later.id, noDue.id])
        #expect(book.tasks(showCompleted: true).last?.id == completed.id)
        #expect(book.pendingCount == 3 && early.isOverdue && !completed.isOverdue && !deleted.isOverdue)
    }
    @Test func newFieldsDecodeLegacyWorkFilesAndDoNotOverwriteCustomerRecords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("data.json")
        let customer = CustomerWorkRecord(account: "a", conversationID: "c", name: "Khách hàng", notes: "Ghi chú hồ sơ cũ")
        let legacy = try JSONSerialization.data(withJSONObject: ["customers": try JSONSerialization.jsonObject(with: JSONEncoder().encode([customer])), "orders": []])
        try legacy.write(to: url)
        let store = WorkStore(url: url)
        #expect(store.error == nil && store.database.notebooks == nil)
        try store.setNote("Ghi chú riêng mới", account: "a", conversationID: "c")
        let reloaded = WorkStore(url: url)
        #expect(reloaded.database.customers == [customer])
        #expect(reloaded.notebook(account: "a", conversationID: "c").note == "Ghi chú riêng mới")
    }
    @Test func persistenceKeepsUnicodeDeadlinesAndOwnerOnlyPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Work/data.json")
        let store = WorkStore(url: url)
        let text = "Khách cần hoa 🌸\nNgân sách: 500.000đ"
        try store.setNote(text, account: "a", conversationID: "c")
        let todo = ConversationTodo(title: "Liên hệ lại", dueAt: Date(timeIntervalSince1970: 1000))
        try store.saveTask(todo, account: "a", conversationID: "c")
        let reloaded = WorkStore(url: url)
        #expect(reloaded.notebook(account: "a", conversationID: "c").note == text)
        #expect(reloaded.notebook(account: "a", conversationID: "c").todos.first?.dueAt == todo.dueAt)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }
    @Test func rejectsInvalidInputsAndDoesNotLoseSavedNoteOnFailure() throws {
        let store = WorkStore(url: nil)
        try store.setNote("Nội dung đang lưu", account: "a", conversationID: "c")
        for text in [String(repeating: "a", count: 20001), "bad\0text"] {
            #expect(throws: (any Error).self) { try store.setNote(text, account: "a", conversationID: "c") }
        }
        #expect(store.notebook(account: "a", conversationID: "c").note == "Nội dung đang lưu")
        for title in [" \n", "bad\0text", String(repeating: "a", count: 301)] {
            #expect(throws: (any Error).self) { try store.saveTask(ConversationTodo(title: title), account: "a", conversationID: "c") }
        }
        #expect(throws: (any Error).self) { try store.setNote("invalid", account: "", conversationID: "c") }
        #expect(store.notebook(account: "a", conversationID: "c").todos.isEmpty)
    }
    @Test func failedStorageWritePreservesExistingData() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("corrupt".utf8).write(to: url)
        let store = WorkStore(url: url)
        #expect(throws: (any Error).self) { try store.setNote("Do not overwrite", account: "a", conversationID: "c") }
        #expect(throws: (any Error).self) { try store.saveTask(ConversationTodo(title: "Do not overwrite"), account: "a", conversationID: "c") }
        #expect(try String(contentsOf: url, encoding: .utf8) == "corrupt")
        #expect(store.database.notebooks == nil)
    }
}
