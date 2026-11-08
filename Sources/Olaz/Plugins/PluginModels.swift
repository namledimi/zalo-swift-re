import Foundation

enum PluginDestination: Hashable {
    case connections
    case assistant, products, work, knowledge
}

struct MCPServerConfiguration: Codable, Equatable, Sendable {
    var command: String?
    var args: [String]?
    var env: [String: String]?
    var url: String?
    var headers: [String: String]?
    var type: String?

    func validate() throws {
        for (name, value) in headers ?? [:] {
            let allowedName = "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
            guard !name.isEmpty, name.utf8.allSatisfy({ allowedName.utf8.contains($0) }),
                  !value.utf8.contains(where: { ($0 < 32 && $0 != 9) || $0 == 127 }) else {
                throw PluginError.message("Header MCP không hợp lệ.")
            }
        }
        if let url, !url.isEmpty {
            guard !url.contains(where: { $0.isWhitespace }),
                  let components = URLComponents(string: url), let host = components.host, !host.isEmpty,
                  components.user == nil, components.password == nil, components.fragment == nil,
                  components.scheme?.lowercased() == "https" || (components.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())) else {
                throw PluginError.message("Dùng URL HTTPS, hoặc HTTP cho server trên localhost.")
            }
            guard command == nil || command == "" else { throw PluginError.message("Mỗi server chỉ dùng command hoặc url.") }
            guard type == nil || type == "http" || type == "streamable-http" else {
                throw PluginError.message("Kết nối URL hiện hỗ trợ Streamable HTTP.")
            }
        } else {
            guard let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PluginError.message("Cần command cho MCP local, hoặc url cho MCP từ xa.")
            }
        }
    }
}

struct MCPPluginConnection: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var configuration: MCPServerConfiguration
    var enabled = false
    var oauth: MCPOAuthSettings?
    var service: MCPConnectionPreset?
    var allowedAbilities: Set<String>?
    /// Explicit tool names; discovering a server never grants its tools to the assistant.
    var allowedTools: Set<String> = []
    var serverKey: String { "olaz_" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
}

struct PluginSettings: Codable, Equatable, Sendable {
    var connections: [MCPPluginConnection] = []
}

struct MCPToolDescriptor: Identifiable, Equatable, Sendable {
    var name: String
    var description: String
    var inputSchema: Data
    var annotations: Data?
    var id: String { name }
}

enum PluginError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { message } else { nil } }
}

enum MCPConfigurationDocument {
    static func parse(_ text: String, name: String) throws -> [MCPPluginConnection] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = text.data(using: .utf8), data.count <= 200_000 else {
            throw PluginError.message("Cấu hình MCP tối đa 200 KB.")
        }
        if !text.hasPrefix("{"), text.contains("://"), !text.hasPrefix("\"") {
            return try urlConnection(text, name: name)
        }
        guard let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw PluginError.message("Dán địa chỉ MCP bắt đầu bằng https:// hoặc cấu hình JSON hợp lệ.")
        }
        if let url = decoded as? String { return try urlConnection(url, name: name) }
        guard let root = decoded as? [String: Any] else {
            throw PluginError.message("Dán địa chỉ MCP hoặc cấu hình JSON chứa url, command hay mcpServers.")
        }
        if root["mcpServers"] != nil, !(root["mcpServers"] is [String: Any]) {
            throw PluginError.message("mcpServers phải là danh sách đối tượng cấu hình theo tên server.")
        }
        let servers = root["mcpServers"] as? [String: Any] ?? [name: root]
        guard !servers.isEmpty, servers.count <= 20 else { throw PluginError.message("Thêm từ 1 đến 20 MCP server mỗi lần.") }
        return try servers.keys.sorted().map { key in
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let raw = servers[key] as? [String: Any] else { throw PluginError.message("Tên hoặc cấu hình server không hợp lệ.") }
            guard let configuration = try? JSONDecoder().decode(MCPServerConfiguration.self, from: JSONSerialization.data(withJSONObject: raw)) else {
                throw PluginError.message("Cấu hình \(key) chưa đúng định dạng. url/command cần là chuỗi; args là danh sách chuỗi; headers/env là đối tượng chứa các chuỗi.")
            }
            try configuration.validate()
            return MCPPluginConnection(name: key, configuration: configuration)
        }
    }

    private static func urlConnection(_ url: String, name: String) throws -> [MCPPluginConnection] {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PluginError.message("Nhập tên cho kết nối MCP.") }
        let configuration = MCPServerConfiguration(url: url.trimmingCharacters(in: .whitespacesAndNewlines), type: "http")
        try configuration.validate()
        return [MCPPluginConnection(name: name, configuration: configuration)]
    }
}
