import SwiftUI

struct ConversationNotesSheet: View {
    let context: ConversationNotebookContext
    @Environment(ZaloEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var loaded = false
    @State private var noteError: String?
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Ghi chú riêng") { close() }
            Text(context.name).font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.bottom, 16)
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $note)
                    .font(.body).lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator).allowsHitTesting(false))
                    .accessibilityLabel("Ghi chú riêng cho hội thoại")
                    .focused($editorFocused)
                HStack {
                    Label("Tự lưu trên máy", systemImage: "internaldrive")
                    Spacer()
                    Text("\(note.count.formatted(.number.locale(Locale(identifier: "vi_VN"))))/20.000 ký tự")
                        .foregroundStyle(note.count > 20_000 ? Color.red : Color.secondary)
                        .monospacedDigit()
                }.font(.caption).foregroundStyle(.secondary)

                if let error = noteError ?? engine.work.error {
                    HStack(alignment: .top) {
                        Text(error).font(.caption).foregroundStyle(.red)
                        Spacer()
                        Button("Thử lưu lại") { saveNote() }.font(.caption)
                    }
                }
            }.padding(20)

            Divider()
            HStack {
                Text("Ghi chú chỉ dành cho bạn.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Xong") { close() }.keyboardShortcut(.cancelAction)
            }.padding(16)
        }
        .frame(width: 540, height: 440)
        .interactiveDismissDisabled()
        .onAppear {
            guard !loaded else { return }
            note = engine.work.notebook(account: context.account, conversationID: context.conversationID).note
            loaded = true
        }
        .task { await Task.yield(); editorFocused = true }
        .onChange(of: note) { _, _ in if loaded { saveNote() } }
        .onChange(of: engine.profile?.userId) { _, now in if now != context.account { dismiss() } }
    }

    private func saveNote() {
        guard loaded else { return }
        guard engine.profile?.userId == context.account else { noteError = "Tài khoản đã thay đổi."; return }
        do {
            try engine.work.setNote(note, account: context.account, conversationID: context.conversationID)
            noteError = nil
        } catch { noteError = error.localizedDescription }
    }

    private func close() {
        saveNote()
        if noteError == nil { dismiss() }
    }
}
