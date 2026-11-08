import Foundation

/// Both providers see a filtered stdio proxy. Credentials stay in its owner-only input file.
enum MCPProviderConfiguration {
    static func isSafeToolName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 128 && name.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:-").contains($0)
        }
    }

    static var proxyExecutable: String {
        if let url = Bundle.main.executableURL, url.lastPathComponent == "Olaz" { return url.path }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/Olaz").path
    }

    static func inputFile(_ connection: MCPPluginConnection, directory: URL) -> URL {
        directory.appendingPathComponent(connection.serverKey + ".json")
    }

    static func prepare(_ connections: [MCPPluginConnection], in directory: URL) throws {
        guard !connections.isEmpty else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var files: [(URL, Data)] = try connections.map { (inputFile($0, directory: directory), try JSONEncoder().encode($0)) }
        files.append((directory.appendingPathComponent("mcp.json"), Data(claude(connections, directory: directory).utf8)))
        for (url, data) in files {
            guard fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw PluginError.message("Không tạo được cấu hình MCP tạm thời.")
            }
        }
    }

    static func codex(_ connections: [MCPPluginConnection], directory: URL) -> String {
        let servers = connections.map { connection -> String in
            let args = ["--mcp-proxy", inputFile(connection, directory: directory).path].map(quote).joined(separator: ",")
            let tools = connection.allowedTools.sorted().map(quote).joined(separator: ",")
            return quote(connection.serverKey) + "={command=" + quote(proxyExecutable) + ",args=[" + args + "],enabled_tools=[" + tools + "],required=true,default_tools_approval_mode=\"approve\"}"
        }
        return "mcp_servers={" + servers.joined(separator: ",") + "}"
    }

    static func claude(_ connections: [MCPPluginConnection], directory: URL) -> String {
        let servers = Dictionary(uniqueKeysWithValues: connections.map { connection in
            (connection.serverKey, ["command": proxyExecutable, "args": ["--mcp-proxy", inputFile(connection, directory: directory).path]] as [String: Any])
        })
        let data = (try? JSONSerialization.data(withJSONObject: ["mcpServers": servers], options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func claudeTools(_ connections: [MCPPluginConnection]) -> [String] {
        connections.flatMap { c in c.allowedTools.sorted().map { "mcp__\(c.serverKey)__\($0)" } }
    }

    private static func quote(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(text)) ?? Data("\"\"".utf8), as: UTF8.self)
    }
}
