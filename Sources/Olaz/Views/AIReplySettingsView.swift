import SwiftUI
import UniformTypeIdentifiers

struct AIReplySettingsView: View {
    @Environment(ZaloEngine.self) private var engine
    @State private var search = ""
    @State private var importError: String?
    @State private var testQuestion = "Chào bạn, bạn có thể hỗ trợ tôi không?"

    var body: some View {
        @Bindable var ai = engine.aiReply
        Section("Trợ lý phản hồi tin nhắn") {
            Toggle("Bật trợ lý AI", isOn: $ai.settings.enabled)
            Picker("Kết nối", selection: $ai.settings.provider) {
                ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
            }
            Picker("Chế độ phản hồi", selection: $ai.settings.mode) {
                ForEach(AIReplyMode.allCases) { Text($0.title).tag($0) }
            }
            Text(ai.settings.mode == .review
                 ? "Câu trả lời xuất hiện trong hội thoại để bạn sửa và gửi."
                 : "AI tự gửi câu trả lời trong các hội thoại bạn chọn bên dưới, khi Olaz đang mở.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Cầu nối chạy trên Mac bằng Codex hoặc Claude Code đã đăng nhập. Nội dung hội thoại được chọn và dữ liệu hướng dẫn được gửi tới OpenAI hoặc Anthropic để tạo câu trả lời.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = ai.storageError { Text(error).font(.caption).foregroundStyle(.red) }
        }

        Section("Kết nối trên máy") {
            HStack {
                TextField("Đường dẫn \(ai.settings.provider.command) (để trống để tự tìm)", text: pathBinding)
                    .textFieldStyle(.roundedBorder)
                Button("Chọn…", action: chooseExecutable)
            }
            TextField("Model (để trống để dùng mặc định của công cụ)", text: $ai.settings.model)
            HStack {
                Button("Kiểm tra công cụ") { Task { await ai.checkConnection() } }
                    .disabled(ai.checking)
                if ai.checking { ProgressView().controlSize(.small) }
            }
            Text(ai.connectionStatus).font(.caption).foregroundStyle(.secondary)
            TextField("Câu hỏi thử cho AI và MCP", text: $testQuestion)
                .accessibilityLabel("Câu hỏi thử cho AI và MCP")
            HStack {
                Button("Thử với câu hỏi này") { Task { await ai.testConnection(question: testQuestion) } }
                    .disabled(ai.testing)
                if ai.testing { ProgressView().controlSize(.small) }
            }
            Text("Thử câu hỏi với dữ liệu hướng dẫn và MCP đang bật, hiển thị công cụ AI đã gọi. Không gửi tin nhắn Zalo.")
                .font(.caption).foregroundStyle(.secondary)
            if let diagnostic = ai.testDiagnostic { Text(diagnostic).font(.caption).foregroundStyle(.secondary) }
            if let result = ai.testResult {
                Text(result).font(.callout).textSelection(.enabled)
            }
            Text("Đăng nhập trước trong Terminal bằng codex login hoặc claude auth login. Kiểm tra công cụ chỉ xác nhận phiên bản, không gửi nội dung hội thoại.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section("Hướng dẫn trả lời") {
            TextEditor(text: $ai.settings.instructions)
                .font(.system(size: 12))
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            Text("Nhập vai trò, cách xưng hô, giọng điệu và quy tắc xử lý khi thiếu thông tin.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(ai.settings.guides) { guide in
                HStack {
                    Label(guide.name, systemImage: "doc.text")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(guide.text.utf8.count), countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                    Button { ai.settings.guides.removeAll { $0.id == guide.id } } label: {
                        Image(systemName: "minus.circle")
                    }.buttonStyle(.borderless).help("Bỏ tài liệu khỏi hướng dẫn AI")
                }
            }
            Button("Thêm dữ liệu hướng dẫn…", systemImage: "doc.badge.plus", action: importGuides)
            Text("Tệp .txt, .md hoặc .json mã hóa UTF-8. Mỗi tệp tối đa 200 KB, tổng 400 KB. Olaz lưu bản sao nội dung; toàn bộ tài liệu được đưa vào mỗi yêu cầu, chưa có tìm kiếm tài liệu theo ngữ nghĩa.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section("Hội thoại áp dụng") {
            if let account = ai.account {
                TextField("Tìm hội thoại", text: $search)
                let selected = ai.settings.conversations(for: account)
                let rows = engine.visibleConversations.filter {
                    $0.id != account && (search.isEmpty || $0.displayName.localizedStandardContains(search))
                }
                ForEach(rows) { conversation in
                    VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: Binding(
                        get: { ai.settings.conversations(for: account).contains(conversation.id) },
                        set: { ai.select(conversation.id, enabled: $0) }
                    )) {
                        Label(conversation.displayName, systemImage: conversation.isGroup ? "person.2" : "person")
                    }
                    .disabled(selected.count >= 20 && !selected.contains(conversation.id))
                    if let error = ai.errors[conversation.id] {
                        Text(error).font(.caption).foregroundStyle(.red)
                    } else if ai.busy.contains(conversation.id) {
                        Text("AI đang soạn câu trả lời…").font(.caption).foregroundStyle(.secondary)
                    } else if ai.drafts[conversation.id] != nil {
                        Text("Có câu trả lời chờ duyệt trong hội thoại.").font(.caption).foregroundStyle(.secondary)
                    }
                    }
                }
                if rows.isEmpty { Text("Không có hội thoại phù hợp.").foregroundStyle(.secondary) }
                Text("Đã chọn \(selected.count)/20 hội thoại cho tài khoản này. Chỉ xử lý tin văn bản mới sau khi bật; không trả lời lịch sử đồng bộ.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Đăng nhập Zalo để chọn hội thoại.").foregroundStyle(.secondary)
            }
        }

        Section("Thời gian và ngữ cảnh") {
            Stepper("Chờ \(ai.settings.delaySeconds) giây để gom tin mới", value: $ai.settings.delaySeconds, in: 2...60)
            Stepper("Dùng tối đa \(ai.settings.contextCount) tin gần nhất", value: $ai.settings.contextCount, in: 2...30)
        }
        .alert("Chưa thêm được tài liệu", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: { Text(importError ?? "") }
    }

    private var pathBinding: Binding<String> {
        Binding(get: { engine.aiReply.settings.executablePath }, set: {
            if engine.aiReply.settings.provider == .codex { engine.aiReply.settings.codexPath = $0 }
            else { engine.aiReply.settings.claudePath = $0 }
        })
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.prompt = "Chọn công cụ"
        if panel.runModal() == .OK, let url = panel.url { pathBinding.wrappedValue = url.path }
    }

    private func importGuides() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.plainText, .json, UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK else { return }
        do {
            for url in panel.urls {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= AIReplySettings.maxGuideBytes else {
                    throw AIClientError.message("\(url.lastPathComponent) lớn hơn 200 KB.")
                }
                try engine.aiReply.addGuide(name: url.lastPathComponent, data: Data(contentsOf: url))
            }
        } catch { importError = error.localizedDescription }
    }
}

struct AIReplyDraftView: View {
    let conversationId: String
    @Environment(ZaloEngine.self) private var engine

    var body: some View {
        let ai = engine.aiReply
        if ai.busy.contains(conversationId) || ai.drafts[conversationId] != nil || ai.errors[conversationId] != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(ai.busy.contains(conversationId) ? "AI đang soạn câu trả lời…" : "Gợi ý từ AI", systemImage: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if ai.busy.contains(conversationId) { ProgressView().controlSize(.small) }
                    Button("Bỏ qua") { ai.userWillSend(conversation: conversationId) }
                        .buttonStyle(.borderless).font(.caption)
                }
                if let draft = ai.drafts[conversationId] {
                    TextEditor(text: Binding(get: { ai.drafts[conversationId]?.text ?? "" }, set: { ai.editDraft(conversation: conversationId, text: $0) }))
                        .font(.system(size: 13)).frame(height: 70)
                    HStack {
                        Text("\(ai.settings.provider.title) · Bạn có thể sửa trước khi gửi")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Gửi câu trả lời") { Task { await ai.send(draft) } }
                            .buttonStyle(.glassProminent)
                            .disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.text.count > 8000)
                    }
                }
                if let error = ai.errors[conversationId] { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12).padding(.top, 8)
        }
    }
}
