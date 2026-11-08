import SwiftUI

struct ConversationNotebookShortcut: View {
    let conversationID: String
    let name: String
    @Environment(ZaloEngine.self) private var engine
    @State private var context: ConversationNotebookContext?
    @State private var taskError: String?

    var body: some View {
        if let account = engine.profile?.userId {
            let book = engine.work.notebook(account: account, conversationID: conversationID)
            let pending = book.tasks(showCompleted: false)
            let hasCompleted = book.todos.contains { $0.deletedAt == nil && $0.isCompleted }
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "note.text").foregroundStyle(.orange).frame(width: 18)
                        Text("Ghi chú").font(.system(size: 13, weight: .semibold))
                        Spacer(minLength: 4)
                        Button { open(account, section: .notes) } label: {
                            Label(book.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Thêm" : "Sửa", systemImage: "square.and.pencil")
                        }
                        .notebookCardAction()
                        .accessibilityLabel("Mở ghi chú riêng")
                        .accessibilityIdentifier("conversation.notebook.open")
                    }
                    if !book.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(book.note)
                            .font(.system(size: 13)).lineSpacing(4)
                            .foregroundStyle(.primary).lineLimit(3).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }.notebookCard()

                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        Image(systemName: "checklist").foregroundStyle(.tint).frame(width: 18)
                        Text("Việc cần làm").font(.system(size: 13, weight: .semibold))
                        Text("\(book.pendingCount)")
                            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(book.pendingCount > 0 ? Color.accentColor : Color.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.08), in: Capsule())
                            .accessibilityLabel("\(book.pendingCount) việc chưa xong")
                        Spacer(minLength: 4)
                        Button { open(account, section: .tasks) } label: { Label("Thêm", systemImage: "plus") }
                            .notebookCardAction()
                            .accessibilityLabel("Thêm việc cho hội thoại")
                            .accessibilityIdentifier("conversation.notebook.add-task")
                    }
                    ForEach(pending.prefix(2)) { todo in
                        HStack(alignment: .top, spacing: 8) {
                            Toggle(isOn: Binding(get: { todo.isCompleted }, set: { completed in
                                guard engine.profile?.userId == account else { return }
                                do {
                                    try engine.work.completeTask(todo.id, completed: completed, account: account, conversationID: conversationID)
                                    taskError = nil
                                } catch { taskError = error.localizedDescription }
                            })) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(todo.title).font(.system(size: 12.5)).foregroundStyle(.primary).lineLimit(2)
                                    if let due = todo.dueAt {
                                        Text((todo.isOverdue ? "Quá hạn · " : "Hạn · ") + due.formatted(.dateTime.locale(Locale(identifier: "vi_VN")).day().month(.twoDigits).hour().minute()))
                                            .font(.system(size: 10.5)).foregroundStyle(todo.isOverdue ? Color.orange : Color.secondary)
                                    }
                                }
                            }.toggleStyle(.checkbox).accessibilityLabel("Hoàn thành: " + todo.title)
                            Spacer(minLength: 0)
                        }
                    }
                    if !book.todos.isEmpty {
                        Button { open(account, section: .tasks, showCompleted: pending.isEmpty && hasCompleted) } label: {
                            HStack(spacing: 4) {
                                Text(pending.isEmpty ? (hasCompleted ? "Xem việc đã hoàn thành" : "Mở danh sách việc") : (pending.count > 2 ? "Xem tất cả \(pending.count) việc" : "Mở danh sách việc"))
                                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                            }.font(.system(size: 11.5, weight: .medium)).foregroundStyle(.tint)
                                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                        }.buttonStyle(.plain).accessibilityIdentifier("conversation.notebook.tasks")
                    }
                    if let taskError { Text(taskError).font(.caption).foregroundStyle(.red) }
                }.notebookCard()
            }
            .sheet(item: $context) { ConversationNotebookSheet(context: $0) }
        }
    }

    private func open(_ account: String, section: ConversationNotebookSection, showCompleted: Bool = false) {
        context = ConversationNotebookContext(account: account, conversationID: conversationID, name: name, section: section, showCompleted: showCompleted)
    }
}

private extension View {
    func notebookCard() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)).allowsHitTesting(false))
    }

    func notebookCardAction() -> some View {
        font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.tint)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            .buttonStyle(.plain)
    }
}

/// Routes each entry point to its own focused sheet without changing the stored notebook.
struct ConversationNotebookSheet: View {
    let context: ConversationNotebookContext

    var body: some View {
        switch context.section {
        case .notes: ConversationNotesSheet(context: context)
        case .tasks: ConversationTodoSheet(context: context)
        }
    }
}
