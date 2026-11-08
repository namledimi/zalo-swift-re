import Foundation
import Darwin

/// A native MCP client for stdio and Streamable HTTP (2025-11-25 lifecycle).
/// Each explicit operation owns a short session; no server starts just by adding its configuration.
@MainActor
final class MCPClient {
    private let configuration: MCPServerConfiguration
    private var stdio: MCPStdioTransport?
    private var session: URLSession?
    private let redirectPolicy = MCPRedirectPolicy()
    private var sessionID: String?
    private var version = "2025-11-25"
    private var nextID = 0

    init(configuration: MCPServerConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        self.session = session
    }

    func start() async throws {
        try configuration.validate()
        if configuration.url == nil || configuration.url == "" {
            stdio = MCPStdioTransport(configuration: configuration)
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 35
            if session == nil { session = URLSession(configuration: config, delegate: redirectPolicy, delegateQueue: nil) }
        }
        let initialized = try await request("initialize", params: [
            "protocolVersion": version, "capabilities": [:], "clientInfo": ["name": "Olaz", "version": "1.0"],
        ])
        let object = try Self.object(initialized)
        if let negotiated = object["protocolVersion"] as? String {
            guard ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"].contains(negotiated) else {
                throw PluginError.message("Server dùng phiên bản MCP chưa được hỗ trợ: \(negotiated).")
            }
            version = negotiated
        }
        _ = try await request("notifications/initialized", notification: true)
    }

    func close() {
        stdio?.close()
        session?.invalidateAndCancel()
    }

    func tools() async throws -> [MCPToolDescriptor] {
        var result: [MCPToolDescriptor] = []
        var cursor: String?
        for _ in 0..<16 {
            let page = try Self.object(await request("tools/list", params: cursor.map { ["cursor": $0] } ?? [:]))
            for raw in page["tools"] as? [[String: Any]] ?? [] {
                guard let name = raw["name"] as? String, MCPProviderConfiguration.isSafeToolName(name) else { continue }
                let schema = try JSONSerialization.data(withJSONObject: raw["inputSchema"] as? [String: Any] ?? ["type": "object"])
                let annotations = try (raw["annotations"] as? [String: Any]).map { try JSONSerialization.data(withJSONObject: $0) }
                result.append(MCPToolDescriptor(name: name, description: raw["description"] as? String ?? "", inputSchema: schema, annotations: annotations))
            }
            cursor = page["nextCursor"] as? String
            if cursor == nil { break }
        }
        var seen: Set<String> = []
        return result.filter { seen.insert($0.name).inserted }
    }

    func call(tool: String, arguments: Data) async throws -> Data {
        let args = try Self.object(arguments)
        return try await request("tools/call", params: ["name": tool, "arguments": args])
    }

    private func request(_ method: String, params: [String: Any] = [:], notification: Bool = false) async throws -> Data {
        nextID += 1
        let id = nextID
        var object: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if !notification { object["id"] = id }
        let body = try JSONSerialization.data(withJSONObject: object)
        let response: Data
        if let stdio {
            response = try await stdio.exchange(body, id: notification ? nil : id)
        } else {
            response = try await http(body: body, id: notification ? nil : id)
        }
        if notification { return Data("{}".utf8) }
        let rpc = try Self.object(response)
        guard (rpc["id"] as? NSNumber)?.intValue == id else { throw PluginError.message("MCP trả về mã yêu cầu không khớp.") }
        if let error = rpc["error"] as? [String: Any] {
            throw PluginError.message("MCP trả về lỗi \((error["code"] as? NSNumber)?.intValue ?? -1). Kiểm tra cấu hình và quyền của server.")
        }
        guard let result = rpc["result"] else { throw PluginError.message("MCP chưa trả về kết quả.") }
        return try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
    }

    private func http(body: Data, id: Int?) async throws -> Data {
        guard let session, let url = configuration.url.flatMap(URL.init(string:)) else {
            throw PluginError.message("Chưa khởi tạo kết nối MCP.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        for (name, value) in configuration.headers ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw PluginError.message("MCP không trả về HTTP hợp lệ.") }
        guard (200..<300).contains(http.statusCode) else {
            var errorBody = Data()
            for try await byte in bytes {
                if errorBody.count >= 16_384 { break }
                errorBody.append(byte)
            }
            throw Self.httpError(status: http.statusCode, body: errorBody)
        }
        if let value = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = value }
        guard id != nil else { return Data("{}".utf8) }
        if (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/event-stream") {
            var event = "", received = 0
            for try await line in bytes.lines {
                received += line.utf8.count
                guard received <= 2_000_000 else { throw PluginError.message("Kết quả MCP vượt quá 2 MB.") }
                if line.isEmpty {
                    if let data = event.data(using: .utf8), let rpc = try? Self.object(data), (rpc["id"] as? NSNumber)?.intValue == id { return data }
                    event = ""
                } else if line.hasPrefix("data:") {
                    event += (event.isEmpty ? "" : "\n") + line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                }
            }
            if let data = event.data(using: .utf8), let rpc = try? Self.object(data), (rpc["id"] as? NSNumber)?.intValue == id { return data }
            throw PluginError.message("Luồng MCP kết thúc trước khi có kết quả.")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2_000_000 else { throw PluginError.message("Kết quả MCP vượt quá 2 MB.") }
            data.append(byte)
        }
        return data
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PluginError.message("MCP trả về JSON không hợp lệ.")
        }
        return object
    }

    static func httpError(status: Int, body: Data) -> PluginError {
        if status == 403, let object = try? Self.object(body), object["cloudflare_error"] as? Bool == true,
           let code = (object["error_code"] as? NSNumber)?.intValue {
            return .message("Cloudflare của server đang chặn client MCP (HTTP 403, mã \(code)). Quản trị server cần cho phép kết nối MCP qua Cloudflare.")
        }
        if status == 401 { return .message("MCP yêu cầu xác thực (HTTP 401). Chọn Sửa… → Xác thực và nhập thông tin do server MCP cung cấp.") }
        if status == 403 { return .message("Server từ chối truy cập MCP (HTTP 403). Kiểm tra quyền truy cập hoặc chính sách của server.") }
        return .message("Kết nối MCP thất bại (HTTP \(status)).")
    }

    static func text(from result: Data) throws -> String {
        let object = try Self.object(result)
        guard object["isError"] as? Bool != true else { throw PluginError.message("Công cụ MCP báo lỗi. Kiểm tra tham số và quyền truy cập.") }
        let blocks = object["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n\n")
        if !text.isEmpty { return text }
        if let structured = object["structuredContent"] { return String(decoding: try JSONSerialization.data(withJSONObject: structured, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self) }
        throw PluginError.message("Công cụ không trả về dữ liệu văn bản.")
    }
}

private final class MCPRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward configured credentials to a redirected host.
    }
}

private final class MCPStdioTransport: @unchecked Sendable {
    private let configuration: MCPServerConfiguration
    private let condition = NSCondition()
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private var started = false, stopped = false
    private var buffer = Data()
    private var receivedBytes = 0
    private var responses: [Int: Data] = [:]

    init(configuration: MCPServerConfiguration) { self.configuration = configuration }

    func close() {
        condition.lock()
        stopped = true
        condition.broadcast()
        let running = process.isRunning
        condition.unlock()
        if running { process.terminate() }
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if running {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    func exchange(_ data: Data, id: Int?) async throws -> Data {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try self.blockingExchange(data, id: id)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.close() }
    }

    private func blockingExchange(_ data: Data, id: Int?) throws -> Data {
        condition.lock(); defer { condition.unlock() }
        guard !stopped else { throw CancellationError() }
        if !started { try startLocked(); started = true }
        try input.fileHandleForWriting.write(contentsOf: data + Data([10]))
        guard let id else { return Data("{}".utf8) }
        let deadline = Date.now.addingTimeInterval(30)
        while responses[id] == nil && !stopped {
            if !condition.wait(until: deadline) { throw PluginError.message("MCP chưa phản hồi trong 30 giây.") }
        }
        if let response = responses.removeValue(forKey: id) { return response }
        throw PluginError.message("MCP local đã đóng kết nối. Kiểm tra command, tham số và đăng nhập của server.")
    }

    private func startLocked() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
        let command = configuration.command ?? ""
        let executable = command.hasPrefix("/") ? command : path.split(separator: ":").map { "\($0)/\(command)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let executable, FileManager.default.isExecutableFile(atPath: executable) else { throw PluginError.message("Không tìm thấy lệnh MCP: \(command).") }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = configuration.args ?? []
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var env = ["HOME": home, "PATH": path, "USER": NSUserName(), "LANG": "en_US.UTF-8", "TMPDIR": FileManager.default.temporaryDirectory.path]
        for (key, value) in configuration.env ?? [:] { env[key] = value }
        process.environment = env
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.receive(handle.availableData) }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            condition.lock(); stopped = true; condition.broadcast(); condition.unlock()
        }
        try process.run()
    }

    private func receive(_ data: Data) {
        condition.lock(); defer { condition.unlock() }
        receivedBytes += data.count
        guard !data.isEmpty, receivedBytes <= 2_000_000 else { stopped = true; condition.broadcast(); return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard let rpc = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let id = rpc["id"] as? NSNumber, rpc["method"] == nil { responses[id.intValue] = line }
            else if let id = rpc["id"], rpc["method"] != nil {
                // No sampling, filesystem roots or elicitation capabilities are advertised by Olaz.
                var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
                if rpc["method"] as? String == "ping" { reply["result"] = [:] }
                else { reply["error"] = ["code": -32601, "message": "Unsupported client method"] }
                if let encoded = try? JSONSerialization.data(withJSONObject: reply) { try? input.fileHandleForWriting.write(contentsOf: encoded + Data([10])) }
            }
        }
        condition.broadcast()
    }
}
