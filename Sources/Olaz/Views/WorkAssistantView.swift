import SwiftUI
import AppKit

struct WorkTargetPicker: View {
    @Binding var target: String
    @Environment(ZaloEngine.self) private var engine
    var body: some View {
        Picker("Hội thoại nhận bản nháp", selection: $target) {
            Text("Chọn hội thoại…").tag("")
            ForEach(engine.visibleConversations) { Text($0.displayName).tag($0.id) }
        }
    }
}

@MainActor enum WorkActions {
    static func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    static func insert(_ text: String, target: String, engine: ZaloEngine, shell: ShellModel) {
        guard let account = engine.profile?.userId, engine.visibleConversations.contains(where: { $0.id == target }), !text.isEmpty else { return }
        engine.workDraft = WorkDraftInsertion(account: account, conversationID: target, text: text)
        shell.open(conversation: target)
    }
}

struct WorkAssistantView: View {
    @Environment(ZaloEngine.self) private var engine
    @Environment(ShellModel.self) private var shell
    @State private var question = ""
    @State private var selectedSources: Set<UUID> = []
    @State private var target = ""
    var body: some View {
        let assistant = engine.workAssistant
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Trợ lý công việc").font(.title2.bold())
                    Text("Tra cứu qua MCP và chuẩn bị nội dung. Lịch sử này giữ trong phiên; trợ lý không tự gửi tin Zalo.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cuộc trò chuyện mới") { assistant.clear() }.disabled(assistant.busy)
            }
            DisclosureGroup("Nguồn MCP đã chọn (\(selectedSources.count))") {
                ForEach(engine.plugins.activeConnections) { connection in
                    Toggle(connection.name, isOn: Binding(get: { selectedSources.contains(connection.id) }, set: { value in
                        assistant.clear()
                        if value { selectedSources.insert(connection.id) } else { selectedSources.remove(connection.id) }
                    })).disabled(assistant.busy)
                }
                Text("Chỉ dùng công cụ đọc đã cấp. WordPress cần chọn abilities riêng trong Kết nối.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if engine.plugins.activeConnections.isEmpty {
                Text("Chưa có nguồn được bật và cấp công cụ. Thêm WordPress, WooCommerce hoặc Facebook ở Kết nối.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            WorkTargetPicker(target: $target)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if assistant.turns.isEmpty {
                            ContentUnavailableView("Hỏi trợ lý ngay tại đây", systemImage: "sparkles", description: Text("Ví dụ: tìm ba mẫu hoa trong ngân sách, tra bài WordPress hoặc tổng hợp thông tin từ nguồn đã chọn."))
                        }
                        ForEach(assistant.turns) { turn in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(turn.isUser ? "Bạn" : "Trợ lý").font(.caption.bold()).foregroundStyle(.secondary)
                                Text(turn.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                if !turn.tools.isEmpty { Text("Đã gọi: " + turn.tools.map { $0.components(separatedBy: "__").last ?? $0 }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                                if !turn.isUser {
                                    HStack {
                                        Button("Sao chép") { WorkActions.copy(turn.text) }
                                        Button("Chèn vào ô soạn Zalo") { WorkActions.insert(turn.text, target: target, engine: engine, shell: shell) }
                                            .disabled(target.isEmpty)
                                    }.font(.caption)
                                }
                            }
                            .padding(14).background(turn.isUser ? Color.accentColor.opacity(0.09) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                            .id(turn.id)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: assistant.turns.count) { _, _ in if let id = assistant.turns.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            if let error = assistant.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            TextEditor(text: $question).frame(height: 75).font(.body)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator)).accessibilityLabel("Câu hỏi cho trợ lý công việc")
            HStack {
                Text(engine.aiReply.settings.provider.title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if assistant.busy {
                    ProgressView().controlSize(.small)
                    Button("Dừng") { assistant.cancel() }
                } else {
                    Button("Hỏi trợ lý") {
                        assistant.ask(question, settings: engine.aiReply.settings, plugins: engine.plugins, sources: selectedSources)
                        question = ""
                    }.buttonStyle(.borderedProminent).disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || question.count > 4000)
                }
            }
        }
        .padding(22)
        .onAppear { if selectedSources.isEmpty { selectedSources = Set(engine.plugins.activeConnections.map(\.id)) } }
        .onChange(of: engine.plugins.settings) { _, _ in assistant.clear(); selectedSources.formIntersection(Set(engine.plugins.activeConnections.map(\.id))) }
        .onChange(of: engine.aiReply.settings) { _, _ in assistant.clear() }
    }
}

struct WordPressAbilitiesView: View {
    let connection: MCPPluginConnection
    @Environment(ZaloEngine.self) private var engine
    var body: some View {
        DisclosureGroup("Quyền abilities WordPress (\(connection.allowedAbilities?.count ?? 0))") {
            VStack(alignment: .leading, spacing: 8) {
                Text("execute-ability chỉ chạy những tên ability bạn chọn ở đây. Quyền công cụ MCP bên trên vẫn cần được cấp.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Tải abilities từ website") { Task { await engine.plugins.loadAbilities(connection.id) } }.disabled(engine.plugins.busy.contains(connection.id))
                ForEach(engine.plugins.abilities[connection.id] ?? []) { ability in
                    Toggle(isOn: Binding(get: { connection.allowedAbilities?.contains(ability.name) == true }, set: {
                        engine.plugins.allowAbility(ability.name, connection: connection.id, enabled: $0)
                        Task { await engine.plugins.loadAbilities(connection.id) }
                    })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ability.label).font(.callout)
                            Text(ability.name + (ability.readOnly ? " · Đọc dữ liệu" : " · Có thể thay đổi dữ liệu / chưa phân loại")).font(.caption).foregroundStyle(.secondary)
                            if connection.allowedAbilities?.contains(ability.name) == true {
                                DisclosureGroup("Schema tham số") { Text(String(decoding: ability.inputSchema, as: UTF8.self)).font(.system(size: 10, design: .monospaced)).textSelection(.enabled) }
                            }
                        }
                    }.disabled(engine.plugins.busy.contains(connection.id))
                }
            }.padding(.top, 8)
        }
    }
}
