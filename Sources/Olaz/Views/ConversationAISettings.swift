import SwiftUI

/// A shortcut to the same per-account conversation selection shown in Settings → AI.
/// Selecting a chat never changes the app-wide AI switch.
struct ConversationAISettings: View {
    let conversationId: String
    @Environment(ZaloEngine.self) private var engine
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsTab.selectionKey) private var settingsTab = SettingsTab.general

    private var selected: Bool {
        guard let account = engine.aiReply.account else { return false }
        return engine.aiReply.settings.conversations(for: account).contains(conversationId)
    }

    private var unavailableReason: String? {
        guard let account = engine.aiReply.account else { return "Đang chờ tài khoản Zalo…" }
        guard engine.visibleConversations.contains(where: { $0.id == conversationId }) else {
            return "AI không xử lý hội thoại đang ẩn hoặc chưa tải xong."
        }
        if !selected, engine.aiReply.settings.conversations(for: account).count >= 20 {
            return "Đã chọn đủ 20 hội thoại. Tắt AI ở một hội thoại khác để thêm hội thoại này."
        }
        return nil
    }

    private var status: String {
        let ai = engine.aiReply
        if let reason = unavailableReason { return reason }
        if let error = ai.storageError { return error }
        if !selected { return "AI đang tắt trong hội thoại này." }
        if let until = ai.policy(conversationId).pausedUntil { return "Tạm dừng đến " + until.formatted(date: .omitted, time: .shortened) }
        if !ai.settings.enabled { return "Đã chọn hội thoại này. Trợ lý AI đang tắt toàn bộ; bật lại trong Cài đặt AI." }
        return ai.settings.provider.title + " · " + (ai.policy(conversationId).mode ?? ai.settings.mode).title
    }

    var body: some View {
        let ai = engine.aiReply
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { selected },
                set: { ai.select(conversationId, enabled: $0) }
            )) {
                Label("AI cho hội thoại này", systemImage: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!selected && unavailableReason != nil)
            .accessibilityIdentifier("conversation.ai.enabled")

            Text(status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if selected {
                Picker("Phản hồi", selection: Binding(get: { ai.policy(conversationId).mode?.rawValue ?? "" }, set: { mode in update { $0.mode = AIReplyMode(rawValue: mode) } })) {
                    Text("Theo cài đặt chung").tag("")
                    ForEach(AIReplyMode.allCases) { Text($0.title).tag($0.rawValue) }
                }.font(.caption)
                if ai.policy(conversationId).pausedUntil != nil {
                    Button("Tiếp tục AI") { ai.pause(conversationId, minutes: 0) }
                } else {
                    Button("Tạm dừng 15 phút") { ai.pause(conversationId, minutes: 15) }
                }
                Picker("Khi tôi gửi tin", selection: Binding(get: { ai.policy(conversationId).takeoverMinutes }, set: { minutes in update { $0.takeoverMinutes = minutes } })) {
                    Text("Giữ AI hoạt động").tag(0)
                    Text("Dừng AI 15 phút").tag(15)
                    Text("Dừng AI 60 phút").tag(60)
                }.font(.caption)
                DisclosureGroup("Nguồn MCP của hội thoại") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(engine.plugins.activeConnections) { connection in
                            Toggle(connection.name, isOn: Binding(get: { ai.policy(conversationId).connectionIDs?.contains(connection.id) ?? true }, set: { enabled in
                                update { policy in
                                    var ids = policy.connectionIDs ?? Set(engine.plugins.activeConnections.map(\.id))
                                    if enabled { ids.insert(connection.id) } else { ids.remove(connection.id) }
                                    policy.connectionIDs = ids
                                }
                            })).font(.caption)
                        }
                        Button("Dùng tất cả nguồn đang bật") { update { $0.connectionIDs = nil } }.font(.caption)
                    }
                }.font(.caption)
            }

            Button("Cài đặt AI…") {
                settingsTab = .ai
                openSettings()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.tint)
            .accessibilityIdentifier("conversation.ai.settings")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    private func update(_ change: (inout AIConversationPolicy) -> Void) {
        var policy = engine.aiReply.policy(conversationId); change(&policy); engine.aiReply.setPolicy(conversationId, policy)
    }
}
