import Foundation
import Darwin

enum AIClientError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}

struct AICommandClient: Sendable {
    struct Reply: Sendable {
        var text: String?
        /// nil for providers whose output does not expose tool events.
        var toolCalls: [String]?
    }
    static func discover(_ provider: AIProvider) -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates = ["\(home)/.local/bin/\(provider.command)", "/opt/homebrew/bin/\(provider.command)",
                          "/usr/local/bin/\(provider.command)"]
        if provider == .codex {
            candidates += ["/Applications/ChatGPT.app/Contents/Resources/codex", "/Applications/Codex.app/Contents/Resources/codex"]
            let extensions = home + "/.vscode/extensions"
            for name in ((try? fm.contentsOfDirectory(atPath: extensions)) ?? []).sorted().reversed()
            where name.hasPrefix("openai.chatgpt-") {
                candidates.append(extensions + "/" + name + "/bin/macos-aarch64/codex")
                candidates.append(extensions + "/" + name + "/bin/macos-x86_64/codex")
            }
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    static func executable(for settings: AIReplySettings) throws -> URL {
        let path = settings.executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolved = path.isEmpty ? discover(settings.provider) : path,
              resolved.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: resolved) else {
            throw AIClientError.message("Chưa tìm thấy \(settings.provider.command). Chọn tệp thực thi hoặc cài công cụ này trước.")
        }
        return URL(fileURLWithPath: resolved)
    }

    static func arguments(for settings: AIReplySettings, output: URL) -> [String] {
        var args: [String]
        switch settings.provider {
        case .codex:
            // Keep the existing login; only Plugin's explicit MCP configuration is supplied to this run.
            args = ["exec", "--ignore-user-config", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only",
                    "--color", "never", "--output-last-message", output.path,
                    "-c", "approval_policy=\"never\"", "-c", "web_search=\"disabled\"",
                    "-c", "project_doc_max_bytes=0"]
            args += ["-c", MCPProviderConfiguration.codex(settings.mcpConnections, directory: output.deletingLastPathComponent())]
            for feature in ["shell_tool", "apps", "plugins", "hooks", "multi_agent", "memories", "browser_use", "computer_use", "image_generation", "view_image", "shell_snapshot"] {
                args += ["--disable", feature]
            }
        case .claude:
            // --bare on some installed versions disables subscription login, so isolate settings explicitly instead.
            args = ["--print", "--output-format", "stream-json", "--verbose", "--no-session-persistence", "--tools", "",
                    "--strict-mcp-config", "--mcp-config", settings.mcpConnections.isEmpty ? "{\"mcpServers\":{}}" : output.deletingLastPathComponent().appendingPathComponent("mcp.json").path, "--setting-sources", "",
                    "--settings", "{\"disableAllHooks\":true}", "--disable-slash-commands",
                    "--system-prompt", settings.mcpConnections.isEmpty
                        ? (settings.forOwner ? "Bạn là trợ lý công việc của chủ tài khoản, trả lời từ dữ liệu được cung cấp. Không tự gửi tin nhắn hay dùng công cụ ngoài phạm vi được cấp." : "Bạn chỉ soạn nội dung trả lời Zalo từ dữ liệu được cung cấp. Không dùng công cụ.")
                        : (settings.forOwner ? "Bạn là trợ lý công việc của chủ tài khoản. Không tự gửi tin Zalo. " : "Bạn soạn nội dung trả lời Zalo. ") + AIReplyPrompt.mcpPolicy]
            let tools = MCPProviderConfiguration.claudeTools(settings.mcpConnections)
            if !tools.isEmpty { args += ["--permission-mode", "dontAsk", "--allowedTools", tools.joined(separator: ",")] }
        }
        if !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["--model", settings.model.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        if settings.provider == .codex { args.append("-") }
        return args
    }

    func check(settings: AIReplySettings) async throws -> String {
        let result = try await AIProcessInvocation(executable: Self.executable(for: settings), arguments: ["--version"], input: "", timeout: 15).run()
        guard result.status == 0 else { throw AIClientError.message("Không chạy được \(settings.provider.command). Hãy kiểm tra đường dẫn.") }
        return String(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
    }

    func reply(settings: AIReplySettings, messages: [AIContextMessage]) async throws -> String? {
        try await replyWithDiagnostics(settings: settings, messages: messages).text
    }

    func replyWithDiagnostics(settings: AIReplySettings, messages: [AIContextMessage]) async throws -> Reply {
        let executable = try Self.executable(for: settings)
        let invocation = AIProcessInvocation(executable: executable, arguments: [], input: try AIReplyPrompt.make(settings: settings, messages: messages), timeout: 90,
            extraEnvironment: settings.provider == .claude ? ["ENABLE_TOOL_SEARCH": "false", "MCP_CONNECTION_NONBLOCKING": "0"] : [:])
        defer { try? FileManager.default.removeItem(at: invocation.directory) }
        try MCPProviderConfiguration.prepare(settings.mcpConnections, in: invocation.directory)
        invocation.arguments = Self.arguments(for: settings, output: invocation.directory.appendingPathComponent("reply.txt"))
        let result = try await invocation.run()
        guard result.status == 0 else {
            throw AIClientError.message("\(settings.provider.title) chưa trả lời được (mã \(result.status)). Kiểm tra đăng nhập bằng \(settings.provider == .codex ? "codex login" : "claude auth login") và hạn mức tài khoản.")
        }
        return try Self.parseReply(provider: settings.provider, stdout: result.stdout, lastMessage: result.lastMessage,
                                   expectedMCPServers: Set(settings.mcpConnections.map(\.serverKey)))
    }

    static func parse(provider: AIProvider, stdout: String, lastMessage: String?) throws -> String? {
        try parseReply(provider: provider, stdout: stdout, lastMessage: lastMessage).text
    }

    static func parseReply(provider: AIProvider, stdout: String, lastMessage: String?, expectedMCPServers: Set<String> = []) throws -> Reply {
        let raw: String
        var toolCalls: [String]?
        if provider == .claude {
            let records: [[String: Any]]
            if let data = stdout.data(using: .utf8), let decoded = try? JSONSerialization.jsonObject(with: data) {
                records = (decoded as? [[String: Any]]) ?? (decoded as? [String: Any]).map { [$0] } ?? []
            } else {
                records = stdout.split(separator: "\n").compactMap { line in
                    (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
                }
            }
            for record in records {
                if let servers = record["mcp_servers"] as? [[String: Any]] {
                    let active = servers.filter { ($0["name"] as? String).map(expectedMCPServers.contains) == true }
                    if Set(active.compactMap { $0["name"] as? String }) != expectedMCPServers || active.contains(where: { $0["status"] as? String != "connected" }) {
                        throw AIClientError.message("Claude chưa kết nối được MCP đã cấp. Kiểm tra kết nối và quyền công cụ trong Plugin; chưa gửi câu trả lời Zalo.")
                    }
                }
            }
            toolCalls = records.flatMap { record -> [String] in
                guard record["type"] as? String == "assistant", let message = record["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { return [] }
                return content.compactMap { block in
                    guard block["type"] as? String == "tool_use", let name = block["name"] as? String,
                          name.hasPrefix("mcp__"), name.utf8.count <= 300,
                          name.utf8.allSatisfy({ byte in byte >= 33 && byte <= 126 }) else { return nil }
                    return name
                }
            }
            guard let object = records.last(where: { $0["type"] as? String == "result" || $0["result"] is String }),
                  object["is_error"] as? Bool != true, let text = object["result"] as? String else {
                throw AIClientError.message("Claude chưa trả về câu trả lời hợp lệ. Kiểm tra đăng nhập Claude Code và hạn mức tài khoản.")
            }
            if let denials = object["permission_denials"] as? [Any], !denials.isEmpty {
                throw AIClientError.message("Claude bị từ chối quyền gọi công cụ. Kiểm tra công cụ đã cấp trong Plugin; chưa gửi câu trả lời Zalo.")
            }
            raw = text
        } else {
            guard let lastMessage else { throw AIClientError.message("Codex chưa trả về câu trả lời.") }
            raw = lastMessage
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "__OLAZ_NO_REPLY__" { return Reply(text: nil, toolCalls: toolCalls) }
        guard !text.isEmpty, text.count <= 8000 else { throw AIClientError.message("Câu trả lời AI trống hoặc dài hơn 8.000 ký tự.") }
        return Reply(text: text, toolCalls: toolCalls)
    }
}

/// One child process per request, with private temporary files, a deadline and cancellation.
/// Private message text is fed through stdin, never interpolated into a shell command or argv.
final class AIProcessInvocation: @unchecked Sendable {
    struct Result: Sendable { var status: Int32; var stdout: String; var lastMessage: String? }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OlazAI-" + UUID().uuidString, isDirectory: true)
    var arguments: [String]
    private let executable: URL
    private let input: String
    private let timeout: TimeInterval
    private let extraEnvironment: [String: String]
    private let lock = NSLock()
    private let process = Process()
    private var cancelled = false
    private var timedOut = false

    init(executable: URL, arguments: [String], input: String, timeout: TimeInterval, extraEnvironment: [String: String] = [:]) {
        self.executable = executable; self.arguments = arguments; self.input = input; self.timeout = timeout
        self.extraEnvironment = extraEnvironment
    }

    func run() async throws -> Result {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try self.execute()) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.stop(timeout: false) }
    }

    private func stop(timeout: Bool) {
        lock.lock(); defer { lock.unlock() }
        if timeout { timedOut = true } else { cancelled = true }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    private func execute() throws -> Result {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: directory) }
        let stdinURL = directory.appendingPathComponent("input.txt")
        let stdoutURL = directory.appendingPathComponent("output.txt")
        let stderrURL = directory.appendingPathComponent("error.txt")
        for (url, data) in [(stdinURL, Data(input.utf8)), (stdoutURL, Data()), (stderrURL, Data())] {
            guard fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw AIClientError.message("Không tạo được tệp tạm cho kết nối AI.")
            }
        }
        let stdin = try FileHandle(forReadingFrom: stdinURL)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stdin.close(); try? stdout.close(); try? stderr.close() }
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let home = fm.homeDirectoryForCurrentUser.path
        process.environment = ["HOME": home, "USER": NSUserName(), "LOGNAME": NSUserName(), "LANG": "en_US.UTF-8",
                               "PATH": [executable.deletingLastPathComponent().path, home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":"),
                               "TMPDIR": fm.temporaryDirectory.path, "NO_COLOR": "1"]
        process.environment?.merge(extraEnvironment) { _, supplied in supplied }
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try process.run() } catch { lock.unlock(); throw error }
        lock.unlock()
        let deadline = DispatchWorkItem { [weak self] in self?.stop(timeout: true) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        process.waitUntilExit()
        deadline.cancel()
        lock.lock(); let wasCancelled = cancelled; let wasTimedOut = timedOut; lock.unlock()
        if wasCancelled { throw CancellationError() }
        if wasTimedOut { throw AIClientError.message("AI chưa phản hồi trong \(Int(timeout)) giây. Hãy thử lại.") }
        func read(_ url: URL) -> String? {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 4_000_000) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        return Result(status: process.terminationStatus, stdout: read(stdoutURL) ?? "", lastMessage: read(directory.appendingPathComponent("reply.txt")))
    }
}
