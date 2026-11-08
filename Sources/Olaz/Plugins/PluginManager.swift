import Foundation
import Observation

@MainActor @Observable
final class PluginManager {
    var settings: PluginSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
            onChange?()
        }
    }
    private(set) var tools: [UUID: [MCPToolDescriptor]] = [:]
    private(set) var status: [UUID: String] = [:]
    private(set) var busy: Set<UUID> = []
    private(set) var authenticating: Set<UUID> = []
    private(set) var results: [UUID: String] = [:]
    private(set) var abilities: [UUID: [MCPAbilityDescriptor]] = [:]
    private(set) var storageError: String?
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onGuideImported: ((String, Data) throws -> Void)?
    @ObservationIgnored private let storageURL: URL?
    @ObservationIgnored private var clients: [UUID: MCPClient] = [:]
    @ObservationIgnored private let oauthStore: any MCPOAuthCredentialStore
    @ObservationIgnored private let oauthClient: MCPOAuthClient
    @ObservationIgnored private var oauthRefreshes: [UUID: Task<MCPOAuthCredentials, any Error>] = [:]
    @ObservationIgnored private var oauthLogins: [UUID: Task<Void, Never>] = [:]

    init(storageURL: URL? = PluginManager.defaultStorageURL,
         oauthStore: any MCPOAuthCredentialStore = MCPOAuthKeychainStore(), oauthClient: MCPOAuthClient = MCPOAuthClient()) {
        self.storageURL = storageURL
        self.oauthStore = MCPOAuthSessionStore(backing: oauthStore); self.oauthClient = oauthClient
        if let storageURL, FileManager.default.fileExists(atPath: storageURL.path) {
            do { settings = try JSONDecoder().decode(PluginSettings.self, from: Data(contentsOf: storageURL)) }
            catch { settings = PluginSettings(); storageError = "Không đọc được cấu hình Plugin. Các kết nối đang tắt." }
        } else { settings = PluginSettings() }
    }

    static var defaultStorageURL: URL {
        ZaloPlatform.defaultUserData.deletingLastPathComponent().appendingPathComponent("Plugins/settings.json")
    }

    var activeConnections: [MCPPluginConnection] {
        storageError == nil ? settings.connections.filter { $0.enabled && !$0.allowedTools.isEmpty } : []
    }

    func add(name: String, document: String, authentication: MCPAuthenticationFields? = nil, service: MCPConnectionPreset? = nil) throws {
        let parsed = try MCPConfigurationDocument.parse(document, name: name)
        let connections = (try authentication?.applying(to: parsed) ?? parsed).map { connection in
            var item = connection
            if let service { item.service = service; if service.isWordPress { item.allowedAbilities = [] } }
            return item
        }
        guard settings.connections.count + connections.count <= 20 else { throw PluginError.message("Tối đa 20 kết nối MCP.") }
        for connection in connections { try editOAuthCredentials(old: nil, new: connection, authentication: authentication) }
        settings.connections += connections
    }

    func remove(_ id: UUID) {
        if settings.connections.first(where: { $0.id == id })?.oauth != nil {
            do { try oauthStore.remove(id) } catch { storageError = error.localizedDescription; return }
        }
        cancelOAuth(id)
        clients[id]?.close()
        clients.removeValue(forKey: id)
        tools.removeValue(forKey: id); status.removeValue(forKey: id); results.removeValue(forKey: id)
        abilities.removeValue(forKey: id)
        settings.connections.removeAll { $0.id == id }
    }

    func update(_ id: UUID, name: String, document: String, authentication: MCPAuthenticationFields? = nil, service: MCPConnectionPreset? = nil) throws {
        let original = try MCPConfigurationDocument.parse(document, name: name)
        let parsed = try authentication?.applying(to: original) ?? original
        guard parsed.count == 1, let replacement = parsed.first,
              let index = settings.connections.firstIndex(where: { $0.id == id }) else {
            throw PluginError.message("Khi sửa kết nối, cấu hình chỉ được chứa một MCP server.")
        }
        var updated = replacement
        if let service { updated.service = service; if service.isWordPress { updated.allowedAbilities = [] } }
        updated.id = id
        try editOAuthCredentials(old: settings.connections[index], new: updated, authentication: authentication)
        cancelOAuth(id)
        clients.removeValue(forKey: id)?.close()
        tools.removeValue(forKey: id); results.removeValue(forKey: id); status.removeValue(forKey: id)
        abilities.removeValue(forKey: id)
        settings.connections[index] = updated
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = settings.connections.firstIndex(where: { $0.id == id }) else { return }
        settings.connections[index].enabled = enabled
    }

    func allowTool(_ name: String, connection id: UUID, enabled: Bool) {
        guard MCPProviderConfiguration.isSafeToolName(name) else { return }
        guard let index = settings.connections.firstIndex(where: { $0.id == id }) else { return }
        if enabled { settings.connections[index].allowedTools.insert(name) }
        else { settings.connections[index].allowedTools.remove(name) }
    }

    func allowAbility(_ name: String, connection id: UUID, enabled: Bool) {
        guard let index = settings.connections.firstIndex(where: { $0.id == id }) else { return }
        if settings.connections[index].allowedAbilities == nil { settings.connections[index].allowedAbilities = [] }
        if enabled { settings.connections[index].allowedAbilities?.insert(name) }
        else { settings.connections[index].allowedAbilities?.remove(name) }
    }

    func executeGranted(_ id: UUID, tool: String, arguments: [String: Any]) async throws -> Data {
        guard !busy.contains(id), let connection = settings.connections.first(where: { $0.id == id }), connection.allowedTools.contains(tool) else {
            throw PluginError.message("Nguồn đang bận hoặc công cụ chưa được cấp quyền.")
        }
        try MCPToolAccess.validateAbilityCall(tool: tool, arguments: arguments, allowed: connection.allowedAbilities)
        busy.insert(id)
        defer { busy.remove(id); clients.removeValue(forKey: id)?.close() }
        let authenticated = try await authenticatedConnection(connection)
        let client = MCPClient(configuration: authenticated.configuration)
        clients[id] = client
        try await client.start()
        let result = try await client.call(tool: tool, arguments: JSONSerialization.data(withJSONObject: arguments))
        guard settings.connections.contains(connection) else { throw CancellationError() }
        return result
    }

    func loadAbilities(_ id: UUID) async {
        guard !busy.contains(id), let connection = settings.connections.first(where: { $0.id == id }) else { return }
        busy.insert(id); status[id] = "Đang tải abilities WordPress…"
        abilities.removeValue(forKey: id)
        defer { busy.remove(id); clients.removeValue(forKey: id)?.close() }
        do {
            let authenticated = try await authenticatedConnection(connection)
            let client = MCPClient(configuration: authenticated.configuration)
            clients[id] = client
            try await client.start()
            let result = try await client.call(tool: MCPToolAccess.discoverAbilities, arguments: Data("{}".utf8))
            let payload = MCPData.unwrapped(try MCPData.payload(result))
            let rows = (payload as? [String: Any])?["abilities"] as? [[String: Any]] ?? payload as? [[String: Any]] ?? []
            var detailedRows: [[String: Any]] = []
            for row in rows.prefix(500) {
                try Task.checkCancellation()
                if let name = row["name"] as? String, connection.allowedAbilities?.contains(name) == true {
                    let info = try await client.call(tool: MCPToolAccess.abilityInfo, arguments: JSONSerialization.data(withJSONObject: ["ability_name": name]))
                    if let detail = MCPData.unwrapped(try MCPData.payload(info)) as? [String: Any], detail["name"] as? String == name { detailedRows.append(detail); continue }
                }
                detailedRows.append(row)
            }
            let parsed = detailedRows.compactMap { row -> MCPAbilityDescriptor? in
                guard let name = row["name"] as? String, !name.isEmpty, name.count <= 200 else { return nil }
                let meta = row["meta"] as? [String: Any] ?? [:]
                let annotation = meta["annotations"] as? [String: Any] ?? row["annotations"] as? [String: Any] ?? [:]
                let readOnly = annotation["destructiveHint"] as? Bool != true && annotation["destructive"] as? Bool != true && (annotation["readonly"] as? Bool == true || annotation["readOnlyHint"] as? Bool == true || ["woocommerce/products-query", "woocommerce/order-notes-query"].contains(name))
                let schema = (try? JSONSerialization.data(withJSONObject: row["input_schema"] as? [String: Any] ?? ["type": "object"])) ?? Data("{}".utf8)
                return MCPAbilityDescriptor(name: name, label: row["label"] as? String ?? name, description: row["description"] as? String ?? "", inputSchema: schema, readOnly: readOnly)
            }
            guard settings.connections.contains(where: { $0 == connection }) else { return }
            abilities[id] = parsed
            status[id] = "Đã tải \(parsed.count) abilities. Chọn quyền ability riêng trước khi dùng công cụ execute-ability."
        } catch { status[id] = error.localizedDescription }
    }

    func assistantConnections(selected: Set<UUID>, readOnly: Bool) async throws -> [MCPPluginConnection] {
        let snapshot = settings
        var result: [MCPPluginConnection] = []
        for connection in activeConnections where selected.contains(connection.id) {
            if tools[connection.id] == nil { await inspect(connection.id) }
            guard let catalog = tools[connection.id], settings.connections.contains(connection) else { throw PluginError.message(status[connection.id] ?? "Nguồn đã thay đổi hoặc không tải được công cụ MCP.") }
            var prepared = try await authenticatedConnection(connection)
            if readOnly {
                prepared.allowedTools = prepared.allowedTools.intersection(Set(catalog.filter(MCPToolAccess.isReadOnly).map(\.name)))
                if let selectedAbilities = connection.allowedAbilities {
                    await loadAbilities(connection.id)
                    let readable = Set((abilities[connection.id] ?? []).filter(\.readOnly).map(\.name)).intersection(selectedAbilities)
                    prepared.allowedAbilities = readable
                    if !readable.isEmpty && connection.allowedTools.contains(MCPToolAccess.executeAbility) { prepared.allowedTools.insert(MCPToolAccess.executeAbility) }
                }
            }
            if !prepared.allowedTools.isEmpty { result.append(prepared) }
        }
        guard settings == snapshot else { throw CancellationError() }
        if !selected.isEmpty && result.isEmpty { throw PluginError.message("Chọn nguồn đã bật và cấp công cụ/ability phù hợp trong Kết nối.") }
        return result
    }

    func inspect(_ id: UUID) async {
        guard !busy.contains(id), let connection = settings.connections.first(where: { $0.id == id }) else { return }
        oauthStore.allowRetry(id)
        busy.insert(id); status[id] = "Đang kết nối…"
        defer { busy.remove(id); clients.removeValue(forKey: id)?.close() }
        do {
            let authenticated = try await authenticatedConnection(connection)
            let client = MCPClient(configuration: authenticated.configuration)
            clients[id] = client
            try await client.start()
            let discovered = try await client.tools()
            guard settings.connections.contains(where: { $0.id == id && $0.configuration == connection.configuration }) else { return }
            tools[id] = discovered
            status[id] = "Kết nối thành công · \(discovered.count) công cụ"
        } catch { if settings.connections.contains(where: { $0.id == id }) { status[id] = error.localizedDescription } }
    }

    func call(_ id: UUID, tool: String, arguments: String) async {
        guard !busy.contains(id), let connection = settings.connections.first(where: { $0.id == id }),
              connection.allowedTools.contains(tool) else { return }
        oauthStore.allowRetry(id)
        busy.insert(id); results[id] = nil
        defer { busy.remove(id); clients.removeValue(forKey: id)?.close() }
        do {
            guard let data = arguments.data(using: .utf8), data.count <= 100_000 else { throw PluginError.message("Tham số công cụ vượt quá 100 KB.") }
            let parameters = try MCPClient.object(data)
            try MCPToolAccess.validateAbilityCall(tool: tool, arguments: parameters, allowed: connection.allowedAbilities)
            let authenticated = try await authenticatedConnection(connection)
            let client = MCPClient(configuration: authenticated.configuration)
            clients[id] = client
            try await client.start()
            let result = try await client.call(tool: tool, arguments: data)
            let text = try MCPClient.text(from: result)
            guard settings.connections.contains(where: { $0.id == id && $0.configuration == connection.configuration && $0.allowedTools.contains(tool) }) else { return }
            results[id] = text
            status[id] = "Đã nhận dữ liệu từ \(tool)"
        } catch { if settings.connections.contains(where: { $0.id == id }) { status[id] = error.localizedDescription } }
    }

    func importResult(_ id: UUID) throws {
        guard let text = results[id], let connection = settings.connections.first(where: { $0.id == id }) else { return }
        guard let onGuideImported else { throw PluginError.message("Chưa kết nối dữ liệu hướng dẫn AI.") }
        try onGuideImported(connection.name + " · MCP", Data(text.utf8))
        status[id] = "Đã thêm kết quả vào dữ liệu hướng dẫn AI"
    }

    func prepareActiveConnections(selected: Set<UUID>? = nil) async throws -> [MCPPluginConnection] {
        var prepared: [MCPPluginConnection] = []
        for connection in activeConnections where selected?.contains(connection.id) ?? true { prepared.append(try await authenticatedConnection(connection)) }
        return prepared
    }

    func startOAuth(_ id: UUID) {
        guard oauthLogins[id] == nil, !busy.contains(id) else { return }
        oauthLogins[id] = Task { [weak self] in
            guard let self else { return }
            await self.authenticate(id, browser: MCPOAuthBrowserSession())
            self.oauthLogins.removeValue(forKey: id)
        }
    }

    func cancelOAuth(_ id: UUID) {
        oauthLogins.removeValue(forKey: id)?.cancel()
        oauthRefreshes.removeValue(forKey: id)?.cancel()
    }

    func authenticate(_ id: UUID, browser: any MCPOAuthBrowser) async {
        guard !busy.contains(id), let connection = settings.connections.first(where: { $0.id == id }),
              let oauth = connection.oauth, let server = connection.configuration.url.flatMap(URL.init(string:)) else { return }
        busy.insert(id); status[id] = "Đang đăng nhập OAuth qua trình duyệt…"
        oauthStore.allowRetry(id)
        authenticating.insert(id)
        defer { busy.remove(id); authenticating.remove(id) }
        do {
            let previous = try oauthStore.read(id)
            let credentials = try await oauthClient.login(server: server, settings: oauth, previous: previous, browser: browser)
            try Task.checkCancellation()
            guard settings.connections.contains(where: { $0.id == id && $0.oauth == oauth && $0.configuration == connection.configuration }) else { return }
            try oauthStore.write(credentials, for: id)
            status[id] = "Đã đăng nhập OAuth. Kiểm tra và tải công cụ để chọn quyền cho AI."
            onChange?()
        } catch is CancellationError { status[id] = "Đã hủy đăng nhập OAuth." }
        catch { status[id] = error.localizedDescription }
    }

    private func editOAuthCredentials(old: MCPPluginConnection?, new: MCPPluginConnection, authentication: MCPAuthenticationFields?) throws {
        let changed = old?.oauth != new.oauth || old?.configuration.url != new.configuration.url
        let secret = authentication?.mode == .oauth ? authentication?.oauthClientSecret ?? "" : ""
        if new.oauth == nil {
            if old?.oauth != nil { try oauthStore.remove(new.id) }
        } else if changed || !secret.isEmpty {
            var credentials = MCPOAuthCredentials()
            credentials.clientID = new.oauth?.clientID ?? ""
            credentials.clientSecret = secret.isEmpty ? nil : secret
            if secret.isEmpty, old?.oauth != nil, old?.oauth?.clientID == new.oauth?.clientID,
               old?.configuration.url == new.configuration.url {
                credentials.clientSecret = try oauthStore.read(new.id)?.clientSecret
            }
            try oauthStore.write(credentials, for: new.id)
        }
    }

    private func authenticatedConnection(_ connection: MCPPluginConnection) async throws -> MCPPluginConnection {
        guard connection.oauth != nil else { return connection }
        guard var credentials = try oauthStore.read(connection.id) else {
            throw PluginError.message("\(connection.name): chọn Đăng nhập OAuth trước khi tải công cụ.")
        }
        guard let resource = credentials.resource.flatMap(URL.init(string:)),
              let server = connection.configuration.url.flatMap(URL.init(string:)),
              MCPOAuthClient.canonical(resource) == MCPOAuthClient.canonical(server) else {
            throw PluginError.message("\(connection.name): chọn Đăng nhập OAuth để cấp quyền cho đúng server này.")
        }
        if credentials.accessToken == nil || credentials.expiresAt.map({ $0 <= Date.now.addingTimeInterval(60) }) == true {
            let task: Task<MCPOAuthCredentials, any Error>
            if let pending = oauthRefreshes[connection.id] { task = pending }
            else {
                task = Task { try await oauthClient.refresh(credentials) }
                oauthRefreshes[connection.id] = task
            }
            defer { oauthRefreshes.removeValue(forKey: connection.id) }
            credentials = try await task.value
            try Task.checkCancellation()
            guard settings.connections.contains(where: { $0.id == connection.id && $0.oauth == connection.oauth && $0.configuration == connection.configuration }) else { throw CancellationError() }
            try oauthStore.write(credentials, for: connection.id)
        }
        guard let token = credentials.accessToken, !token.isEmpty else { throw PluginError.message("Chọn Đăng nhập OAuth để đăng nhập lại.") }
        var result = connection
        result.oauth = nil
        var headers = result.configuration.headers ?? [:]
        headers = headers.filter { $0.key.caseInsensitiveCompare("Authorization") != .orderedSame }
        headers["Authorization"] = "Bearer " + token
        result.configuration.headers = headers
        try result.configuration.validate()
        return result
    }

    private func save() {
        guard let storageURL else { return }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(settings).write(to: storageURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
            storageError = nil
        } catch { storageError = "Không lưu được cấu hình Plugin. Kết nối tự động đã tạm dừng." }
    }
}
