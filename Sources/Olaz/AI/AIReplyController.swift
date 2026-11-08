import Foundation
import Observation

@MainActor @Observable
final class AIReplyController {
    var settings: AIReplySettings {
        didSet {
            guard settings != oldValue else { return }
            if settings.provider != oldValue.provider || settings.executablePath != oldValue.executablePath {
                connectionStatus = "Chưa kiểm tra kết nối"
            }
            resetWork()
            scheduleResumes()
            testResult = nil
            testDiagnostic = nil
            save()
            onConfigurationChanged?()
        }
    }
    private(set) var drafts: [String: AIReplyDraft] = [:]
    private(set) var busy: Set<String> = []
    private(set) var errors: [String: String] = [:]
    private(set) var connectionStatus = "Chưa kiểm tra kết nối"
    private(set) var checking = false
    private(set) var testing = false
    private(set) var testResult: String?
    private(set) var testDiagnostic: String?
    private(set) var storageError: String?
    private(set) var account: String?

    @ObservationIgnored var onConfigurationChanged: (() -> Void)?
    @ObservationIgnored var sender: ((String, String) async -> Bool)?
    @ObservationIgnored var validateTrigger: ((String, String) async -> Bool)?
    @ObservationIgnored var pluginConnections: () async throws -> [MCPPluginConnection] = { [] }
    @ObservationIgnored var scopedPluginConnections: ((Set<UUID>?) async throws -> [MCPPluginConnection])?
    @ObservationIgnored private let storageURL: URL?
    @ObservationIgnored private var gate = AIReplyGate()
    @ObservationIgnored private var contexts: [String: [AIContextMessage]] = [:]
    @ObservationIgnored private var jobs: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var jobIDs: [String: UUID] = [:]
    @ObservationIgnored private var generating = false
    @ObservationIgnored private var resumeJobs: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let generate: @Sendable (AIReplySettings, [AIContextMessage]) async throws -> String?
    @ObservationIgnored private let generateForTesting: @Sendable (AIReplySettings, [AIContextMessage]) async throws -> AICommandClient.Reply
    @ObservationIgnored private let debounce: @Sendable (Int) async throws -> Void

    init(storageURL: URL? = AIReplyController.defaultStorageURL,
         generate: (@Sendable (AIReplySettings, [AIContextMessage]) async throws -> String?)? = nil,
         debounce: @escaping @Sendable (Int) async throws -> Void = { seconds in
             try await Task.sleep(for: .seconds(seconds))
         }) {
        self.storageURL = storageURL
        self.generate = generate ?? { settings, messages in try await AICommandClient().reply(settings: settings, messages: messages) }
        if let generate {
            self.generateForTesting = { settings, messages in AICommandClient.Reply(text: try await generate(settings, messages), toolCalls: nil) }
        } else {
            self.generateForTesting = { settings, messages in try await AICommandClient().replyWithDiagnostics(settings: settings, messages: messages) }
        }
        self.debounce = debounce
        if let storageURL, FileManager.default.fileExists(atPath: storageURL.path) {
            do { settings = try JSONDecoder().decode(AIReplySettings.self, from: Data(contentsOf: storageURL)) }
            catch { settings = AIReplySettings(); storageError = "Không đọc được cấu hình AI. Tính năng đang tắt." }
        } else { settings = AIReplySettings() }
    }

    static var defaultStorageURL: URL {
        ZaloPlatform.defaultUserData.deletingLastPathComponent().appendingPathComponent("AI/settings.json")
    }

    var watchedConversations: Set<String> {
        guard settings.enabled, storageError == nil, let account else { return [] }
        return settings.conversations(for: account).filter { settings.policy(account: account, conversation: $0).pausedUntil == nil }
    }

    func activate(account: String?) {
        guard self.account != account else { return }
        resetWork()
        self.account = account
        scheduleResumes()
    }

    func policy(_ conversation: String) -> AIConversationPolicy {
        guard let account else { return AIConversationPolicy() }
        return settings.policy(account: account, conversation: conversation)
    }

    func setPolicy(_ conversation: String, _ policy: AIConversationPolicy) {
        guard let account else { return }
        var all = settings.conversationPoliciesByAccount ?? [:]
        all[account, default: [:]][conversation] = policy
        settings.conversationPoliciesByAccount = all
    }

    func pause(_ conversation: String, minutes: Int) {
        var value = policy(conversation)
        value.pausedUntil = minutes > 0 ? Date.now.addingTimeInterval(Double(min(1440, minutes)) * 60) : nil
        setPolicy(conversation, value)
    }

    private func scheduleResumes() {
        resumeJobs.values.forEach { $0.cancel() }; resumeJobs = [:]
        guard let account else { return }
        for (id, policy) in settings.conversationPoliciesByAccount?[account] ?? [:] {
            guard let until = policy.pausedUntil else { continue }
            resumeJobs[id] = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow))) } catch { return }
                guard let self, self.account == account, self.policy(id).pausedUntil == until else { return }
                self.resumeJobs.removeValue(forKey: id)
                self.pause(id, minutes: 0)
            }
        }
    }

    func select(_ conversation: String, enabled: Bool) {
        guard let account else { return }
        var ids = settings.conversations(for: account)
        if enabled {
            guard ids.count < 20 || ids.contains(conversation) else { return }
            ids.insert(conversation)
        } else { ids.remove(conversation) }
        settings.conversationsByAccount[account] = ids
    }

    func receive(account: String, conversation: String, messages: [AIContextMessage]) {
        guard self.account == account, watchedConversations.contains(conversation), let last = messages.last else { return }
        let previous = contexts[conversation]?.last
        contexts[conversation] = messages
        if previous != last {
            jobs.removeValue(forKey: conversation)?.cancel()
            jobIDs.removeValue(forKey: conversation)
            busy.remove(conversation)
            drafts.removeValue(forKey: conversation)
            errors.removeValue(forKey: conversation)
        }
        guard let trigger = gate.observe(messages, conversation: conversation) else { return }
        let settings = self.settings
        let policy = self.policy(conversation)
        let token = UUID()
        jobIDs[conversation] = token
        busy.insert(conversation)
        jobs[conversation] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.jobIDs[conversation] == token {
                    self.jobs.removeValue(forKey: conversation)
                    self.jobIDs.removeValue(forKey: conversation)
                    self.busy.remove(conversation)
                }
            }
            do {
                try await self.debounce(min(60, max(2, settings.delaySeconds)))
                // One model invocation at a time, even when several conversations receive messages together.
                while self.generating { try await Task.sleep(for: .milliseconds(150)) }
                try Task.checkCancellation()
                guard self.isCurrent(trigger.id, conversation: conversation), self.settings == settings,
                      let context = self.contexts[conversation] else { return }
                let text = try await self.generateOne(settings: settings, messages: context, policy: policy)
                try Task.checkCancellation()
                guard let text, self.isCurrent(trigger.id, conversation: conversation), self.settings == settings else { return }
                let draft = AIReplyDraft(conversationId: conversation, triggerId: trigger.id, text: text)
                self.drafts[conversation] = draft
                if (policy.mode ?? settings.mode) == .automatic { await self.send(draft) }
            } catch is CancellationError {
                // New messages, configuration changes, manual replies and logout all cancel pending work.
            } catch {
                if self.jobIDs[conversation] == token { self.errors[conversation] = error.localizedDescription }
            }
        }
    }

    private func generateOne(settings: AIReplySettings, messages: [AIContextMessage], policy: AIConversationPolicy) async throws -> String? {
        generating = true
        defer { generating = false }
        var runtime = settings
        if let scopedPluginConnections { runtime.mcpConnections = try await scopedPluginConnections(policy.connectionIDs) }
        else { runtime.mcpConnections = try await pluginConnections() }
        if let ids = policy.connectionIDs { runtime.mcpConnections = runtime.mcpConnections.filter { ids.contains($0.id) } }
        runtime.mode = policy.mode ?? settings.mode
        return try await generate(runtime, messages)
    }

    private func isCurrent(_ trigger: String, conversation: String) -> Bool {
        watchedConversations.contains(conversation) && contexts[conversation]?.last?.id == trigger
            && gate.isCurrent(trigger, conversation: conversation)
    }

    /// Revalidate against the renderer too: its newest message may have changed before its snapshot reached Swift.
    func send(_ draft: AIReplyDraft) async {
        let account = self.account
        guard drafts[draft.conversationId]?.id == draft.id, isCurrent(draft.triggerId, conversation: draft.conversationId),
              !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, draft.text.count <= 8000,
              await validateTrigger?(draft.conversationId, draft.triggerId) == true,
              account == self.account, isCurrent(draft.triggerId, conversation: draft.conversationId),
              drafts[draft.conversationId]?.id == draft.id else { return }
        // Remove before awaiting to prevent a double click from sending twice. Failures require a deliberate retry.
        drafts.removeValue(forKey: draft.conversationId)
        if await sender?(draft.conversationId, draft.text) != true, account == self.account {
            errors[draft.conversationId] = "Zalo chưa nhận câu trả lời. Hãy kiểm tra hội thoại trước khi gửi lại."
        }
    }

    func editDraft(conversation: String, text: String) {
        drafts[conversation]?.text = text
    }

    func dismiss(conversation: String) {
        drafts.removeValue(forKey: conversation)
        errors.removeValue(forKey: conversation)
    }

    func userWillSend(conversation: String) {
        jobs.removeValue(forKey: conversation)?.cancel()
        jobIDs.removeValue(forKey: conversation)
        busy.remove(conversation)
        contexts.removeValue(forKey: conversation)
        dismiss(conversation: conversation)
        let minutes = policy(conversation).takeoverMinutes
        if minutes > 0, let account, settings.conversations(for: account).contains(conversation) { pause(conversation, minutes: minutes) }
    }

    func resetWork() {
        jobs.values.forEach { $0.cancel() }
        jobs = [:]; jobIDs = [:]; contexts = [:]; drafts = [:]; busy = []; errors = [:]
        gate = AIReplyGate()
    }

    func cancelUnavailable(conversations: Set<String>) {
        let active = Set(contexts.keys).union(jobs.keys).union(drafts.keys)
        for id in active.subtracting(conversations) { userWillSend(conversation: id) }
    }

    func checkConnection() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        let snapshot = settings
        do {
            let version = try await AICommandClient().check(settings: snapshot)
            guard settings.provider == snapshot.provider, settings.executablePath == snapshot.executablePath else { return }
            connectionStatus = "Đã tìm thấy \(version). Công cụ cần được đăng nhập sẵn."
        } catch { connectionStatus = error.localizedDescription }
    }

    /// An explicit Settings action: a fictional greeting, never a real Zalo conversation or a Zalo send.
    func testConnection(question: String = "Chào bạn, bạn có thể hỗ trợ tôi không?") async {
        guard !testing else { return }
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.count <= 4000 else { testResult = "Nhập câu hỏi thử tối đa 4.000 ký tự."; return }
        testing = true
        testResult = nil
        testDiagnostic = nil
        defer { testing = false }
        let snapshot = settings
        do {
            while generating { try await Task.sleep(for: .milliseconds(150)) }
            generating = true
            defer { generating = false }
            var runtime = snapshot
            runtime.mcpConnections = try await pluginConnections()
            let result = try await generateForTesting(runtime, [
                AIContextMessage(id: "test", text: question, isMine: false, date: .now),
            ])
            if settings == snapshot {
                let diagnostic: String
                if let calls = result.toolCalls {
                    diagnostic = calls.isEmpty ? "AI chưa gọi công cụ MCP trong lần thử này."
                        : "AI đã gọi MCP: " + calls.map { $0.components(separatedBy: "__").last ?? $0 }.joined(separator: ", ")
                } else { diagnostic = "Đã cấp \(runtime.mcpConnections.count) kết nối MCP cho lần thử." }
                testDiagnostic = diagnostic
                testResult = result.text ?? "AI chọn không trả lời tin mẫu."
            }
        } catch {
            if settings == snapshot { testResult = error.localizedDescription }
        }
    }

    func addGuide(name: String, data: Data) throws {
        guard data.count <= AIReplySettings.maxGuideBytes,
              settings.guides.reduce(0, { $0 + $1.text.utf8.count }) + data.count <= AIReplySettings.maxTotalGuideBytes else {
            throw AIClientError.message("Mỗi tài liệu tối đa 200 KB, tổng tài liệu tối đa 400 KB.")
        }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw AIClientError.message("Hãy chọn tệp văn bản UTF-8: .txt, .md hoặc .json.")
        }
        settings.guides.append(AIGuide(name: name, text: text))
    }

    private func save() {
        guard let storageURL else { return }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(settings).write(to: storageURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
            storageError = nil
        } catch { storageError = "Không lưu được cấu hình AI. Phản hồi tự động đã tạm dừng." }
    }
}
