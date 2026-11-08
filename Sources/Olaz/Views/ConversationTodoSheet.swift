import SwiftUI

private enum ConversationTodoFilter: Hashable {
    case pending, completed, deleted

    var emptyTitle: String {
        switch self {
        case .pending: "Chưa có việc cần làm"
        case .completed: "Chưa có việc đã hoàn thành"
        case .deleted: "Không có việc đã gỡ"
        }
    }

    var emptyHint: String {
        switch self {
        case .pending: "Thêm công việc ở ô phía trên để bắt đầu."
        case .completed: "Những việc bạn tích hoàn thành sẽ hiện ở đây."
        case .deleted: "Bạn có thể khôi phục các việc đã gỡ tại đây."
        }
    }
}

struct ConversationTodoSheet: View {
    let context: ConversationNotebookContext
    @Environment(ZaloEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var newTask = ""
    @State private var filter: ConversationTodoFilter
    @State private var editing: ConversationTodo?
    @State private var taskError: String?
    @FocusState private var newTaskFocused: Bool

    init(context: ConversationNotebookContext) {
        self.context = context
        _filter = State(initialValue: context.showCompleted ? .completed : .pending)
    }

    private var book: ConversationNotebook { engine.work.notebook(account: context.account, conversationID: context.conversationID) }
    private var completed: [ConversationTodo] { book.tasks(showCompleted: true).filter(\.isCompleted) }
    private var deleted: [ConversationTodo] { book.tasks(showCompleted: true, deleted: true) }
    private var tasks: [ConversationTodo] {
        switch filter {
        case .pending: book.tasks(showCompleted: false)
        case .completed: completed
        case .deleted: deleted
        }
    }
    private var canAdd: Bool { !newTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && newTask.count <= 300 }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Việc cần làm") { dismiss() }
            HStack {
                Text(context.name)
                Spacer()
                Text("\(book.pendingCount) chưa xong").monospacedDigit()
            }.font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.bottom, 16)
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    TextField("Thêm việc cần làm…", text: $newTask).textFieldStyle(.roundedBorder)
                        .onSubmit { add() }
                        .accessibilityLabel("Tên việc cần làm mới")
                        .focused($newTaskFocused)
                    Button("Thêm", systemImage: "plus") { add() }.buttonStyle(.borderedProminent)
                        .disabled(!canAdd)
                }
                if newTask.count > 300 { Text("Tên việc tối đa 300 ký tự.").font(.caption).foregroundStyle(.red) }
                Picker("Danh sách việc", selection: $filter) {
                    Text("Đang làm · \(book.pendingCount)").tag(ConversationTodoFilter.pending)
                    Text("Đã xong · \(completed.count)").tag(ConversationTodoFilter.completed)
                    Text("Đã gỡ · \(deleted.count)").tag(ConversationTodoFilter.deleted)
                }.pickerStyle(.segmented).labelsHidden()
                if let error = taskError ?? engine.work.error { Text(error).font(.caption).foregroundStyle(.red) }
            }.padding(20)

            ScrollView {
                LazyVStack(spacing: 8) {
                    if tasks.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: filter == .deleted ? "trash" : "checkmark.circle")
                                .font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
                            Text(filter.emptyTitle).font(.headline)
                            Text(filter.emptyHint).font(.callout).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 48)
                    }
                    ForEach(tasks) { todo in taskRow(todo) }
                }.padding(.horizontal, 20).padding(.bottom, 16)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                Text("Công việc riêng cho chat này · Lưu trên máy").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Xong") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
        }.frame(width: 560, height: 500)
            .task { await Task.yield(); newTaskFocused = true }
            .onChange(of: engine.profile?.userId) { _, now in if now != context.account { dismiss() } }
            .sheet(item: $editing) { ConversationTodoEditor(context: context, todo: $0) }
    }

    private func taskRow(_ todo: ConversationTodo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if filter != .deleted {
                Toggle(isOn: Binding(get: { todo.isCompleted }, set: { complete in
                    perform { try engine.work.completeTask(todo.id, completed: complete, account: context.account, conversationID: context.conversationID) }
                })) {
                    taskContent(todo)
                }.toggleStyle(.checkbox).accessibilityLabel("Hoàn thành: " + todo.title)
            } else { taskContent(todo) }
            Spacer(minLength: 0)
            if filter == .deleted {
                Button("Khôi phục") {
                    perform { try engine.work.restoreTask(todo.id, account: context.account, conversationID: context.conversationID) }
                }.font(.caption)
            } else {
                Menu {
                    Button("Sửa…") { editing = todo }
                    Button("Gỡ việc", role: .destructive) {
                        perform { try engine.work.removeTask(todo.id, account: context.account, conversationID: context.conversationID) }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 26, height: 22) }
                    .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("Tùy chọn việc: " + todo.title)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    private func taskContent(_ todo: ConversationTodo) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(todo.title).strikethrough(todo.isCompleted)
                .foregroundStyle(todo.isCompleted || filter == .deleted ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
            if let due = todo.dueAt {
                Label((todo.isOverdue ? "Quá hạn · " : "Hạn · ") + due.formatted(.dateTime.locale(Locale(identifier: "vi_VN")).day().month(.twoDigits).year().hour().minute()), systemImage: "clock")
                    .font(.caption).foregroundStyle(todo.isOverdue ? Color.orange : Color.secondary)
            }
        }
    }

    private func add() {
        guard canAdd else { return }
        perform {
            try engine.work.saveTask(ConversationTodo(title: newTask), account: context.account, conversationID: context.conversationID)
            newTask = ""
            filter = .pending
            newTaskFocused = true
        }
    }

    private func perform(_ action: () throws -> Void) {
        guard engine.profile?.userId == context.account else { taskError = "Tài khoản đã thay đổi."; return }
        do { try action(); taskError = nil } catch { taskError = error.localizedDescription }
    }
}

private struct ConversationTodoEditor: View {
    let context: ConversationNotebookContext
    @State var todo: ConversationTodo
    @Environment(ZaloEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sửa việc cần làm").font(.title2.bold())
            TextField("Nội dung công việc", text: $todo.title, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Nội dung công việc")
            Toggle("Có hạn xử lý", isOn: Binding(get: { todo.dueAt != nil }, set: { todo.dueAt = $0 ? Date.now.addingTimeInterval(3600) : nil }))
            if todo.dueAt != nil {
                DatePicker("Hạn xử lý", selection: Binding(get: { todo.dueAt ?? .now }, set: { todo.dueAt = $0 })).datePickerStyle(.field)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Hủy") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Lưu việc") {
                    do {
                        guard engine.profile?.userId == context.account else { throw PluginError.message("Tài khoản đã thay đổi.") }
                        try engine.work.saveTask(todo, account: context.account, conversationID: context.conversationID)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(todo.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || todo.title.count > 300)
            }
        }.padding(24).frame(width: 480)
            .onChange(of: engine.profile?.userId) { _, now in if now != context.account { dismiss() } }
    }
}
