import SwiftUI

enum SettingsTab: String {
    case general, appearance, notifications, privacy, stickers, account, ai, savedReplies
    static let selectionKey = "olaz.settings.selectedTab"
}

/// The Settings window (⌘,): one tab per topic, each a grouped `Form`. The notification, hidden-chat and sticker tabs embed the
/// sections of their own files, which read and write the official client's settings.
struct SettingsView: View {
    @AppStorage(SettingsTab.selectionKey) private var selectedTab = SettingsTab.general

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Chung", systemImage: "gearshape", value: SettingsTab.general) {
                SettingsPane(height: 210) { GeneralSettings() }
            }
            Tab("Giao diện", systemImage: "paintpalette", value: SettingsTab.appearance) {
                SettingsPane(height: 700) { AppearanceSettings() }
            }
            Tab("Thông báo", systemImage: "bell.badge", value: SettingsTab.notifications) {
                SettingsPane(height: 440) { NotificationSettingsView() }
            }
            Tab("Quyền riêng tư", systemImage: "lock", value: SettingsTab.privacy) {
                SettingsPane(height: 300) { PrivacySettings() }
            }
            Tab("Sticker", systemImage: "face.smiling", value: SettingsTab.stickers) {
                SettingsPane(height: 160) { StickerSettingsSection() }
            }
            Tab("Tài khoản", systemImage: "person.crop.circle", value: SettingsTab.account) {
                SettingsPane(height: 400) { AccountSettings() }
            }
            Tab("AI", systemImage: "sparkles", value: SettingsTab.ai) {
                SettingsPane(height: 700) { AIReplySettingsView() }
            }
            Tab("Tin nhắn mẫu", systemImage: "text.badge.plus", value: SettingsTab.savedReplies) {
                SavedReplySettingsView()
            }
        }
        .frame(minWidth: 720)
    }
}

/// One tab's grouped form at the window's fixed width; a tall section list scrolls instead of resizing the window.
private struct SettingsPane<Content: View>: View {
    let height: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .frame(width: 520, height: height)
    }
}

// MARK: - Chung

private struct GeneralSettings: View {
    @AppStorage("olaz.appearance") private var appearance = Appearance.system

    var body: some View {
        Section("Chế độ giao diện") {
            Picker("Chế độ", selection: $appearance) {
                ForEach(Appearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        // Only a bundled app has a version; a bare `swift run` binary has none to show.
        if let version = Self.version {
            Section("Về \(AppBrand.name)") {
                LabeledContent("Phiên bản", value: version)
            }
        }
    }

    private static var version: String? {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case (let short?, let build?) where short != build: return "\(short) (\(build))"
        default: return short
        }
    }
}

// MARK: - Quyền riêng tư

/// Hidden-chat setup. The official section only exists once the adapter published and the feature is on, so the tab says why
/// it is empty otherwise.
private struct PrivacySettings: View {
    @Environment(ZaloEngine.self) private var engine

    var body: some View {
        let state = engine.conversationActions
        if state.loaded, state.hiddenEnabled {
            HiddenChatSettingsSection()
        } else {
            Section("Thiết lập ẩn trò chuyện") {
                Text(state.loaded ? "Tính năng ẩn trò chuyện chưa được bật cho tài khoản này." : "Đang tải thiết lập từ Zalo…")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Tài khoản

private struct AccountSettings: View {
    @Environment(ZaloEngine.self) private var engine

    var body: some View {
        Section {
            HStack(spacing: 14) {
                if let profile = engine.profile {
                    RemoteAvatar(url: profile.avatar, name: profile.displayName, size: 52)
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.profile?.displayName ?? "Chưa đăng nhập")
                        .font(.system(size: 15, weight: .semibold))
                    if let phone = engine.profile?.phone, !phone.isEmpty {
                        Text(phone).font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("Tài khoản Zalo").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
        Section("Sao lưu & đồng bộ") {
            LabeledContent("Đồng bộ tin nhắn từ điện thoại") {
                Button("Đồng bộ ngay") { engine.startTransfer() }
                    .disabled(!engine.canStartTransfer)
            }
            if let reason = engine.transferStartBlockedReason {
                Text(ZaloEngine.transferBlockedText(reason)).font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("Engine") {
            LabeledContent("Giao thức") { Text("Zalo PC \(engine.clientVersion ?? "—") (mã chính thức)") }
            LabeledContent("Hội thoại") { Text(engine.conversationActions.hiddenKnown ? "\(engine.visibleConversations.count)" : "—") }
        }
        Section {
            Button("Đăng xuất", role: .destructive) { engine.logOut() }
                .disabled(engine.profile == nil)
        }
    }
}
