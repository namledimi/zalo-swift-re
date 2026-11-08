import Foundation

extension ZaloEngine {
    func configureAIReply() {
        aiReply.pluginConnections = { [weak self] in try await self?.plugins.prepareActiveConnections() ?? [] }
        aiReply.scopedPluginConnections = { [weak self] selected in try await self?.plugins.prepareActiveConnections(selected: selected) ?? [] }
        plugins.onGuideImported = { [weak self] name, data in try self?.aiReply.addGuide(name: name, data: data) }
        plugins.onChange = { [weak self] in
            self?.aiReply.resetWork()
            self?.workAssistant.clear()
        }
        aiReply.onConfigurationChanged = { [weak self] in self?.syncAIWatching() }
        aiReply.sender = { [weak self] conversation, text in
            guard let self, case .ready = self.phase, self.profile != nil,
                  self.visibleConversations.contains(where: { $0.id == conversation }) else { return false }
            return await self.sendText(text, to: conversation, isAIReply: true)
        }
        aiReply.validateTrigger = { [weak self] conversation, trigger in
            guard let self, case .ready = self.phase, self.profile != nil,
                  let data = try? JSONSerialization.data(withJSONObject: [conversation, trigger]),
                  let args = String(data: data, encoding: .utf8) else { return false }
            return await self.host?.evaluate("return window.__zaloAI ? window.__zaloAI.isCurrent(...\(args)) : false;") as? Bool == true
        }
        aiWatchSignature = nil
    }

    func syncAIWatching() {
        let account: String?
        if case .ready = phase { account = profile?.userId } else { account = nil }
        if aiReply.account != account { workAssistant.clear(); workProducts.clear(); workDraft = nil }
        aiReply.activate(account: account)
        let visible = Set(visibleConversations.filter { $0.id != profile?.userId }.map(\.id))
        let ids = Array(aiReply.watchedConversations.intersection(visible)).sorted().prefix(20)
        aiReply.cancelUnavailable(conversations: Set(ids))
        let signature = (account ?? "") + ":" + ids.joined(separator: ",")
        guard signature != aiWatchSignature, let host,
              let data = try? JSONSerialization.data(withJSONObject: Array(ids)),
              let json = String(data: data, encoding: .utf8) else { return }
        aiWatchSignature = signature
        Task { [weak self] in
            let ok = await host.evaluate("return window.__zaloAI ? window.__zaloAI.watch(\(json)) : false;") as? Bool
            if ok != true, self?.aiWatchSignature == signature { self?.aiWatchSignature = nil }
        }
    }

    func handleAIReply(state: [String: Any]) {
        guard case .ready = phase, let json = state["aiReply"] as? [String: Any],
              let account = json["account"] as? String, account == profile?.userId,
              let conversation = json["conversationId"] as? String,
              visibleConversations.contains(where: { $0.id == conversation }) else { return }
        let messages = (json["messages"] as? [[String: Any]] ?? []).compactMap {
            Self.chatMessage($0, fallbackConversation: conversation)
        }.map { AIContextMessage(id: $0.id, text: $0.text, isMine: $0.isMine, date: $0.date, isText: $0.kind == .text) }
        aiReply.receive(account: account, conversation: conversation, messages: messages)
    }
}
