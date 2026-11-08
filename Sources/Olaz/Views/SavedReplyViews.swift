import SwiftUI

struct SavedReplySettingsView: View {
    @Environment(ZaloEngine.self) private var engine
    var body: some View {
        Group {
            if let account = engine.profile?.userId {
                SavedReplyLibrary(account: account).id(account)
            } else {
                ContentUnavailableView("Đăng nhập Zalo để quản lý mẫu", systemImage: "text.badge.plus", description: Text("Tin nhắn mẫu lưu riêng cho từng tài khoản trên máy này."))
            }
        }.frame(width: 640, height: 560)
    }
}

struct SavedReplyPickerSheet: View {
    let account: String
    let insert: (SavedReply) -> Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(ZaloEngine.self) private var engine
    var body: some View {
        VStack(spacing: 0) {
            SavedReplyLibrary(account: account) { reply in
                guard insert(reply) else { return false }
                dismiss(); return true
            }
            Divider()
            HStack { Spacer(); Button("Đóng") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(14)
        }.frame(width: 640, height: 590)
        .onChange(of: engine.profile?.userId) { _, now in if now != account { dismiss() } }
    }
}

private struct SavedReplyLibrary: View {
    let account: String
    var insert: ((SavedReply) -> Bool)?
    @Environment(ZaloEngine.self) private var engine
    @State private var search = ""
    @State private var showDeleted = false
    @State private var editing: SavedReply?
    @State private var error: String?
    private var records: [SavedReply] {
        if !showDeleted { return engine.savedReplies.matches(account: account, query: search) }
        let key = SavedReply.folded(search)
        return engine.savedReplies.replies(account: account, deleted: true).filter {
            key.isEmpty || SavedReply.folded($0.shortcut + " " + $0.title + " " + $0.body).contains(key)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tin nhắn mẫu").font(.title2.bold())
                Spacer()
                Button("Thêm mẫu", systemImage: "plus") { editing = SavedReply(account: account, shortcut: "", title: "", body: "") }
                    .disabled(engine.savedReplies.storageError != nil).buttonStyle(.borderedProminent)
            }
            Text("Gõ /dia-chi trong ô soạn để tìm mẫu. Enter hoặc Tab chèn nội dung; bạn kiểm tra rồi gửi. Lưu riêng cho tài khoản Zalo hiện tại trên máy này.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Tìm tên, lệnh hoặc nội dung mẫu", text: $search).textFieldStyle(.roundedBorder)
            Toggle("Hiện mẫu đã gỡ", isOn: $showDeleted).font(.caption)
            if let error = error ?? engine.savedReplies.storageError { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if records.isEmpty {
                        ContentUnavailableView(showDeleted ? "Không có mẫu đã gỡ phù hợp" : "Chưa có mẫu phù hợp", systemImage: "text.bubble", description: Text("Tạo lệnh như /dia-chi, /gio-mo-cua hoặc /thanh-toan với nội dung của bạn."))
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(records) { reply in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("/" + reply.shortcut).font(.system(.callout, design: .monospaced).weight(.semibold)).foregroundStyle(.tint)
                                Text(reply.title).font(.headline).lineLimit(1)
                                Spacer()
                            }
                            Text(reply.body).font(.callout).lineLimit(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            HStack {
                                if showDeleted {
                                    Button("Khôi phục") { perform { try engine.savedReplies.restore(reply.id, account: account) } }
                                } else {
                                    if let insert {
                                        Button("Chèn vào ô soạn") {
                                            if !insert(reply) { error = "Tài khoản hoặc hội thoại đã thay đổi. Đóng cửa sổ và mở lại danh sách mẫu." }
                                        }.buttonStyle(.borderedProminent)
                                    }
                                    Button("Sửa") { editing = reply }
                                    Button("Gỡ", role: .destructive) { perform { try engine.savedReplies.remove(reply.id, account: account) } }
                                }
                            }.font(.caption)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            Text("\(engine.savedReplies.replies(account: account).count)/300 mẫu đang dùng · Gỡ mẫu có thể khôi phục lại.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20)
            .sheet(item: $editing) { SavedReplyEditor(reply: $0) }
            .onChange(of: engine.profile?.userId) { _, _ in editing = nil; search = ""; error = nil }
    }
    private func perform(_ action: () throws -> Void) {
        guard engine.profile?.userId == account else { error = "Tài khoản đã thay đổi."; return }
        do { try action(); error = nil } catch { self.error = error.localizedDescription }
    }
}

struct SavedReplyEditor: View {
    @State var reply: SavedReply
    @Environment(ZaloEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var automaticShortcut: Bool

    init(reply: SavedReply) {
        _reply = State(initialValue: reply)
        _automaticShortcut = State(initialValue: reply.shortcut.isEmpty)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Lưu tin nhắn mẫu").font(.title2.bold())
            TextField("Tên mẫu, ví dụ Địa chỉ cửa hàng", text: $reply.title).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Tên tin nhắn mẫu")
            HStack {
                TextField("Lệnh, ví dụ /dia-chi", text: Binding(get: { reply.shortcut }, set: {
                    automaticShortcut = false; reply.shortcut = $0; error = nil
                })).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Lệnh tin nhắn mẫu")
                Button("Tạo lại từ tên") { automaticShortcut = true; generateShortcut() }
                    .disabled(reply.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Lệnh tự tạo theo tên mẫu; bạn có thể sửa lại. Dùng chữ thường, số, - hoặc _, tối đa 40 ký tự.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Nội dung").font(.callout.weight(.semibold))
            TextEditor(text: $reply.body).font(.body).frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator)).accessibilityLabel("Nội dung tin nhắn mẫu")
            Text("\(reply.body.count)/8.000 ký tự · Lưu mẫu chưa gửi tin nhắn.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("Hủy") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Lưu mẫu") {
                    do {
                        guard reply.account == engine.profile?.userId else { throw SavedReplyError.message("Tài khoản đã thay đổi. Mở lại màn hình tạo mẫu.") }
                        try engine.savedReplies.save(reply); dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(reply.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reply.shortcut.isEmpty || reply.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reply.body.count > SavedReply.maxBodyLength)
            }
        }.padding(22).frame(width: 530, height: 470)
            .onAppear { if automaticShortcut { generateShortcut() } }
            .onChange(of: reply.title) { _, _ in if automaticShortcut { generateShortcut() }; error = nil }
            .onChange(of: engine.profile?.userId) { _, now in if now != reply.account { dismiss() } }
    }
    private func generateShortcut() {
        let reserved = Set(engine.savedReplies.replies(account: reply.account).filter { $0.id != reply.id }.map(\.shortcut))
        let suggested = SavedReply.suggestedShortcut(for: reply.title, reserved: reserved)
        reply.shortcut = suggested.isEmpty ? "" : "/" + suggested
        error = nil
    }
}

struct SavedReplySuggestions: View {
    let replies: [SavedReply]
    @Binding var selected: Int
    let pick: (SavedReply) -> Void
    let manage: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Tin nhắn mẫu").font(.caption.weight(.semibold))
                Spacer()
                Button("Quản lý…", action: manage).font(.caption).buttonStyle(.plain).foregroundStyle(.tint)
            }.padding(.horizontal, 10).padding(.top, 4)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(replies.enumerated()), id: \.element.id) { index, reply in
                            Button { pick(reply) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text("/" + reply.shortcut).font(.system(.callout, design: .monospaced).weight(.semibold))
                                        Text(reply.title).font(.callout).lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    Text(reply.body.replacingOccurrences(of: "\n", with: " ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }.padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(selected == index ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 10))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(reply.id)
                                .onHover { if $0 { selected = index } }
                                .accessibilityLabel("Chèn mẫu /\(reply.shortcut): \(reply.title)")
                                .accessibilityAddTraits(selected == index ? .isSelected : [])
                        }
                    }
                }.scrollIndicators(.hidden)
                    .onChange(of: selected) { _, index in if replies.indices.contains(index) { proxy.scrollTo(replies[index].id) } }
            }.frame(height: min(CGFloat(replies.count) * 56, 224))
            Text("↑ ↓ chọn · Enter / Tab chèn · Esc đóng").font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 3)
        }.padding(6).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .contain).accessibilityLabel("Gợi ý tin nhắn mẫu")
    }
}
