import Foundation
import Observation

@MainActor @Observable final class WorkStore {
    private(set) var database = WorkDatabase()
    private(set) var error: String?
    @ObservationIgnored private let url: URL?
    init(url: URL? = WorkStore.defaultURL) {
        self.url = url
        if let url, FileManager.default.fileExists(atPath: url.path) {
            do { database = try JSONDecoder().decode(WorkDatabase.self, from: Data(contentsOf: url)) }
            catch { self.error = "Không đọc được dữ liệu công việc. Chưa ghi đè dữ liệu cũ." }
        }
    }
    static var defaultURL: URL { ZaloPlatform.defaultUserData.deletingLastPathComponent().appendingPathComponent("Work/data.json") }
    func notebook(account: String, conversationID: String) -> ConversationNotebook {
        database.notebooks?.first { $0.account == account && $0.conversationID == conversationID }
            ?? ConversationNotebook(account: account, conversationID: conversationID)
    }
    func setNote(_ note: String, account: String, conversationID: String) throws {
        var book = notebook(account: account, conversationID: conversationID)
        guard book.note != note else { return }
        book.note = note
        try saveNotebook(book)
    }
    func saveTask(_ input: ConversationTodo, account: String, conversationID: String) throws {
        var todo = try input.validated()
        var book = notebook(account: account, conversationID: conversationID)
        if let index = book.todos.firstIndex(where: { $0.id == todo.id }) {
            if todo.deletedAt == nil, book.todos[index].deletedAt != nil, book.todos.filter({ $0.deletedAt == nil }).count >= 300 {
                throw PluginError.message("Hội thoại đã đủ 300 việc. Gỡ việc khác trước khi khôi phục.")
            }
            todo.createdAt = book.todos[index].createdAt
            todo.updatedAt = .now; book.todos[index] = todo
        } else {
            guard book.todos.filter({ $0.deletedAt == nil }).count < 300 else { throw PluginError.message("Mỗi hội thoại có tối đa 300 việc đang lưu. Gỡ việc cũ trước khi thêm.") }
            book.todos.append(todo)
        }
        try saveNotebook(book)
    }
    func completeTask(_ id: UUID, completed: Bool, account: String, conversationID: String) throws {
        guard var todo = notebook(account: account, conversationID: conversationID).todos.first(where: { $0.id == id && $0.deletedAt == nil }) else { return }
        todo.completedAt = completed ? .now : nil
        try saveTask(todo, account: account, conversationID: conversationID)
    }
    func removeTask(_ id: UUID, account: String, conversationID: String) throws {
        guard var todo = notebook(account: account, conversationID: conversationID).todos.first(where: { $0.id == id && $0.deletedAt == nil }) else { return }
        todo.deletedAt = .now
        try saveTask(todo, account: account, conversationID: conversationID)
    }
    func restoreTask(_ id: UUID, account: String, conversationID: String) throws {
        let book = notebook(account: account, conversationID: conversationID)
        guard var todo = book.todos.first(where: { $0.id == id && $0.deletedAt != nil }) else { return }
        guard book.todos.filter({ $0.deletedAt == nil }).count < 300 else { throw PluginError.message("Hội thoại đã đủ 300 việc. Gỡ việc khác trước khi khôi phục.") }
        todo.deletedAt = nil
        try saveTask(todo, account: account, conversationID: conversationID)
    }
    private func saveNotebook(_ input: ConversationNotebook) throws {
        guard !input.account.isEmpty, !input.conversationID.isEmpty, input.account.count <= 200, input.conversationID.count <= 200,
              input.note.count <= 20000, !input.note.contains("\0") else { throw PluginError.message("Ghi chú tối đa 20.000 ký tự và cần tài khoản/hội thoại hợp lệ.") }
        var next = database
        var book = input; book.updatedAt = .now
        var books = next.notebooks ?? []
        if let index = books.firstIndex(where: { $0.id == book.id }) { books[index] = book }
        else { books.append(book) }
        next.notebooks = books
        try persist(next)
    }
    func customer(account: String, conversationID: String, name: String) -> CustomerWorkRecord {
        database.customers.first { $0.account == account && $0.conversationID == conversationID }
            ?? CustomerWorkRecord(account: account, conversationID: conversationID, name: name)
    }
    func save(_ customer: CustomerWorkRecord) throws {
        var next = database
        if let index = next.customers.firstIndex(where: { $0.id == customer.id }) { next.customers[index] = customer }
        else { next.customers.append(customer) }
        try persist(next)
    }
    func save(_ order: WorkOrderDraft) throws {
        guard !order.lines.isEmpty, order.lines.allSatisfy({ $0.quantity > 0 && $0.quantity <= 999 && ($0.unitPrice == nil || (!$0.unitPrice!.isNaN && $0.unitPrice! >= 0)) }) else { throw PluginError.message("Đơn nháp cần số lượng từ 1 đến 999 và giá không âm.") }
        var next = database
        if let index = next.orders.firstIndex(where: { $0.id == order.id }) { next.orders[index] = order }
        else { next.orders.append(order) }
        try persist(next)
    }
    func finishFollowUp(_ id: String) throws {
        guard var record = database.customers.first(where: { $0.id == id }) else { return }
        record.followUpAt = nil
        try save(record)
    }
    private func persist(_ next: WorkDatabase) throws {
        guard error == nil else { throw PluginError.message(error!) }
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(next)
            let temp = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".tmp")
            guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw PluginError.message("Không lưu được dữ liệu công việc.") }
            defer { try? FileManager.default.removeItem(at: temp) }
            if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: temp) }
            else { try FileManager.default.moveItem(at: temp, to: url) }
        }
        database = next
    }
}
