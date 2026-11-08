import Foundation

/// A provider-launched stdio adapter, not a Zalo server. Only the selected external tools are exposed.
@MainActor
final class MCPProxy {
    private let connection: MCPPluginConnection
    private let client: MCPClient
    private var initialized = false
    private var jobs: [String: Task<Void, Never>] = [:]

    init(connection: MCPPluginConnection) {
        self.connection = connection
        client = MCPClient(configuration: connection.configuration)
    }

    static func run(configurationPath: String) -> Int32 {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configurationPath))
            guard data.count <= 200_000 else { throw PluginError.message("Cấu hình MCP quá lớn.") }
            let connection = try JSONDecoder().decode(MCPPluginConnection.self, from: data)
            let proxy = MCPProxy(connection: connection)
            DispatchQueue.global().async {
                while let line = readLine() {
                    let data = Data(line.utf8)
                    Task { @MainActor in proxy.receive(data) }
                }
                Task { @MainActor in
                    proxy.close()
                    CFRunLoopStop(CFRunLoopGetMain())
                }
            }
            CFRunLoopRun()
            proxy.close()
            return 0
        } catch {
            FileHandle.standardError.write(Data("Olaz could not start the configured MCP connection.\n".utf8))
            return 1
        }
    }

    private func close() {
        jobs.values.forEach { $0.cancel() }; jobs = [:]
        client.close()
    }

    private func receive(_ data: Data) {
        guard data.count <= 1_000_000, let rpc = try? MCPClient.object(data), let method = rpc["method"] as? String else { return }
        let params = rpc["params"] as? [String: Any] ?? [:]
        if method == "notifications/cancelled", let id = params["requestId"], let key = Self.key(id) {
            jobs.removeValue(forKey: key)?.cancel()
            return
        }
        guard let id = rpc["id"], let key = Self.key(id), jobs[key] == nil,
              let encodedID = try? JSONSerialization.data(withJSONObject: id, options: [.fragmentsAllowed]) else { return }
        let parameters = (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8)
        jobs[key] = Task { [weak self] in
            guard let self else { return }
            defer { jobs.removeValue(forKey: key) }
            let responseID = (try? JSONSerialization.jsonObject(with: encodedID, options: [.fragmentsAllowed])) ?? NSNull()
            do {
                let result = try await perform(method, parameters: parameters)
                try Task.checkCancellation()
                write(["jsonrpc": "2.0", "id": responseID, "result": result])
            } catch {
                guard !Task.isCancelled else { return }
                write(["jsonrpc": "2.0", "id": responseID, "error": ["code": -32000, "message": error.localizedDescription]])
            }
        }
    }

    private func perform(_ method: String, parameters: Data) async throws -> [String: Any] {
        let params = try MCPClient.object(parameters)
        if method == "initialize" {
            guard !initialized else { throw PluginError.message("MCP already initialized") }
            try await client.start()
            initialized = true
            let requested = params["protocolVersion"] as? String ?? "2025-11-25"
            return ["protocolVersion": ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"].contains(requested) ? requested : "2025-11-25",
                    "capabilities": ["tools": [:]], "serverInfo": ["name": "olaz-plugin", "version": "1.0"]]
        }
        guard initialized else { throw PluginError.message("Initialize MCP first") }
        switch method {
        case "ping": return [:]
        case "resources/list": return ["resources": []]
        case "prompts/list": return ["prompts": []]
        case "tools/list":
            let tools = try await client.tools().filter { connection.allowedTools.contains($0.name) }
            return ["tools": try tools.map { tool in
                var descriptor: [String: Any] = ["name": tool.name, "description": tool.description, "inputSchema": try MCPClient.object(tool.inputSchema)]
                if let annotations = tool.annotations { descriptor["annotations"] = try MCPClient.object(annotations) }
                return descriptor
            }]
        case "tools/call":
            guard let name = params["name"] as? String, connection.allowedTools.contains(name), MCPProviderConfiguration.isSafeToolName(name) else {
                throw PluginError.message("Công cụ chưa được cấp quyền trong Plugin của Olaz.")
            }
            try MCPToolAccess.validateAbilityCall(tool: name, arguments: params["arguments"] as? [String: Any] ?? [:], allowed: connection.allowedAbilities)
            let arguments = try JSONSerialization.data(withJSONObject: params["arguments"] as? [String: Any] ?? [:])
            return try MCPClient.object(await client.call(tool: name, arguments: arguments))
        default: throw PluginError.message("MCP method not supported")
        }
    }

    private static func key(_ id: Any) -> String? {
        (try? JSONSerialization.data(withJSONObject: id, options: [.fragmentsAllowed]))?.base64EncodedString()
    }

    private func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), data.count <= 2_000_000 else { return }
        try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
    }
}
