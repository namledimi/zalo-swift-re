import Foundation
import Testing
@testable import Olaz

@MainActor @Suite(.serialized) struct PluginTests {
    private var fixture: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/testing/mcp-fixture.py").path
    }

    private func configuration(value: String = "Fixture data: ready") -> MCPServerConfiguration {
        MCPServerConfiguration(command: "/usr/bin/python3", args: [fixture], env: ["OLAZ_FIXTURE_VALUE": value])
    }

    @Test func parsesStandardMCPConfigurationAndStartsDisabled() throws {
        let connections = try MCPConfigurationDocument.parse(#"{"mcpServers":{"one":{"command":"/usr/bin/python3","args":["a b"]},"two":{"url":"https://example.com/mcp"}}}"#, name: "unused")
        #expect(connections.map(\.name) == ["one", "two"])
        #expect(connections.allSatisfy { !$0.enabled && $0.allowedTools.isEmpty })
        #expect(connections[0].configuration.args == ["a b"])
    }

    @Test func acceptsDirectMCPURLsAndTrimsPastedWhitespace() throws {
        let connections = try MCPConfigurationDocument.parse(" \n https://api.hoatuoipeony.vn/mcp \n", name: " Hoa tươi MCP ")
        let connection = try #require(connections.first)
        #expect(connections.count == 1)
        #expect(connection.name == "Hoa tươi MCP")
        #expect(connection.configuration.url == "https://api.hoatuoipeony.vn/mcp")
        #expect(connection.configuration.type == "http")
        #expect(!connection.enabled && connection.allowedTools.isEmpty)
        let quoted = try MCPConfigurationDocument.parse(#""https://api.hoatuoipeony.vn/mcp""#, name: "Hoa tươi")
        #expect(quoted.first?.configuration.url == connection.configuration.url)
    }

    @Test func invalidURLAndJSONInputsHaveActionableVietnameseErrors() {
        for input in ["not JSON", "[]", #"{"mcpServers":[]}"#, #"{"url":123}"#] {
            do {
                _ = try MCPConfigurationDocument.parse(input, name: "Test")
                Issue.record("Unexpectedly accepted invalid input")
            } catch {
                #expect(error is PluginError)
                #expect(!error.localizedDescription.contains("The data"))
            }
        }
        for url in ["http://example.com/mcp", "ftp://example.com/mcp", "https://user:pass@example.com/mcp", "https://example.com/mcp\nhttps://other.example/mcp"] {
            #expect(throws: (any Error).self) { try MCPConfigurationDocument.parse(url, name: "Test") }
        }
    }

    @Test func distinguishesCloudflareBlocksFromAuthenticationErrors() {
        let cloudflare = Data(#"{"cloudflare_error":true,"error_code":1010,"error_name":"browser_signature_banned"}"#.utf8)
        let blocked = MCPClient.httpError(status: 403, body: cloudflare).localizedDescription
        #expect(blocked.contains("Cloudflare"))
        #expect(blocked.contains("1010"))
        #expect(!blocked.contains("header xác thực"))
        #expect(MCPClient.httpError(status: 401, body: Data()).localizedDescription.contains("xác thực"))
        #expect(MCPClient.httpError(status: 403, body: Data()).localizedDescription.contains("quyền truy cập"))
    }

    @Test func authenticationFormsGenerateAndRestoreBearerAndAPIKeyHeaders() throws {
        var fields = MCPAuthenticationFields()
        fields.mode = .bearer
        fields.token = " Bearer fixture-token "
        fields.extraHeaders = #"{"X-Tenant-ID":"fixture"}"#
        let headers = try fields.makeHeaders()
        #expect(headers == ["Authorization": "Bearer fixture-token", "X-Tenant-ID": "fixture"])
        let restored = MCPAuthenticationFields(headers: ["authorization": "Bearer fixture-token", "X-Tenant-ID": "fixture"])
        #expect(restored.mode == .bearer && restored.token == "fixture-token")
        #expect(try restored.makeHeaders() == headers)

        fields.mode = .apiKey
        fields.headerName = "X-Service-Key"
        fields.token = "fixture-api-key"
        fields.extraHeaders = "{}"
        let apiHeaders = try fields.makeHeaders()
        #expect(apiHeaders == ["X-Service-Key": "fixture-api-key"])
        let restoredAPI = MCPAuthenticationFields(headers: apiHeaders)
        #expect(restoredAPI.mode == .apiKey && restoredAPI.headerName == "X-Service-Key")
        #expect(try restoredAPI.makeHeaders() == apiHeaders)
    }

    @Test func basicAuthenticationPreservesUnicodeAndColonsInPasswords() throws {
        var fields = MCPAuthenticationFields()
        fields.mode = .basic; fields.username = "người-dùng"; fields.password = "fixture:password"
        fields.extraHeaders = #"{"X-Tenant-ID":"fixture"}"#
        let headers = try fields.makeHeaders()
        #expect(headers["Authorization"] == "Basic " + Data("người-dùng:fixture:password".utf8).base64EncodedString())
        let restored = MCPAuthenticationFields(headers: headers)
        #expect(restored.mode == .basic)
        #expect(restored.username == fields.username && restored.password == fields.password)
        #expect(try restored.makeHeaders() == headers)
    }

    @Test func authenticationRejectsMissingValuesInjectionAndConflictingHeaders() throws {
        var fields = MCPAuthenticationFields()
        for mode in [MCPAuthenticationMode.bearer, .apiKey, .basic] {
            fields.mode = mode
            #expect(throws: (any Error).self) { try fields.makeHeaders() }
        }
        fields.mode = .bearer; fields.token = "fixture-token"
        fields.extraHeaders = #"{"authorization":"Bearer conflicting"}"#
        #expect(throws: (any Error).self) { try fields.makeHeaders() }
        fields.extraHeaders = "{}"; fields.token = "fixture\r\nX-Injected: value"
        #expect(throws: (any Error).self) { try fields.makeHeaders() }
        fields.mode = .apiKey; fields.token = "fixture"; fields.headerName = "Bad Header"
        #expect(throws: (any Error).self) { try fields.makeHeaders() }
        fields.mode = .basic; fields.username = "user:wrong"; fields.password = "fixture"
        #expect(throws: (any Error).self) { try fields.makeHeaders() }
        fields.username = "user"; fields.password = "fixture\npassword"
        #expect(throws: (any Error).self) { try fields.makeHeaders() }
        fields.mode = .custom; fields.extraHeaders = #"{"X-Key":123}"#
        #expect(throws: (any Error).self) { try fields.makeHeaders() }
    }

    @Test func customHeadersRoundTripAndNoAuthenticationRemovesStoredHeaders() throws {
        let original = ["Authorization": "Custom fixture", "X-Tenant-ID": "fixture"]
        var fields = MCPAuthenticationFields(headers: original)
        #expect(fields.mode == .custom)
        #expect(try fields.makeHeaders() == original)
        fields.mode = .none
        #expect(try fields.makeHeaders().isEmpty)
    }

    @Test func authenticationAppliesToOneHTTPConnectionAndPersistsEdits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let manager = PluginManager(storageURL: url)
        var fields = MCPAuthenticationFields()
        fields.mode = .bearer; fields.token = "fixture-token"
        try manager.add(name: "Remote", document: "https://fixture.invalid/mcp", authentication: fields)
        let connection = try #require(manager.settings.connections.first)
        #expect(connection.configuration.headers == ["Authorization": "Bearer fixture-token"])
        #expect(PluginManager(storageURL: url).settings.connections == manager.settings.connections)
        manager.setEnabled(connection.id, true)
        manager.allowTool("lookup", connection: connection.id, enabled: true)
        fields.mode = .none
        try manager.update(connection.id, name: "Remote edited", document: "https://fixture.invalid/mcp", authentication: fields)
        #expect(manager.settings.connections[0].id == connection.id)
        #expect(manager.settings.connections[0].configuration.headers == nil)
        #expect(!manager.settings.connections[0].enabled && manager.settings.connections[0].allowedTools.isEmpty)
        #expect(throws: (any Error).self) { try fields.applying(to: [connection, connection]) }
        let local = MCPPluginConnection(name: "Local", configuration: configuration())
        #expect(throws: (any Error).self) { try fields.applying(to: [local]) }
    }

    @Test func rejectsAmbiguousInsecureAndUnsupportedEndpoints() {
        for document in [#"{"url":"http://example.com/mcp"}"#, #"{"url":"https://user:secret@example.com/mcp"}"#,
                         #"{"command":"cmd","url":"https://example.com/mcp"}"#, #"{"url":"https://example.com/sse","type":"sse"}"#,
                         #"{"mcpServers":{}}"#, #"{"args":[]}"#] {
            #expect(throws: (any Error).self) { try MCPConfigurationDocument.parse(document, name: "test") }
        }
        #expect(throws: Never.self) { try MCPServerConfiguration(url: "http://127.0.0.1:1234/mcp").validate() }
    }

    @Test func toolNamesCannotInjectApprovalWildcards() {
        for name in ["*", "search,*", "bad[tool]", "bad tool", ""] { #expect(!MCPProviderConfiguration.isSafeToolName(name)) }
        #expect(MCPProviderConfiguration.isSafeToolName("drive.search_v2"))
    }

    @Test func secretsAreInPrivateFilesAndNotProviderArgumentsOrAISettings() throws {
        var connection = MCPPluginConnection(name: "Fixture", configuration: configuration(value: "MOCK_SECRET_VALUE"))
        connection.enabled = true; connection.allowedTools = ["lookup_knowledge"]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try MCPProviderConfiguration.prepare([connection], in: directory)
        for file in [MCPProviderConfiguration.inputFile(connection, directory: directory), directory.appendingPathComponent("mcp.json")] {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        var settings = AIReplySettings()
        settings.mcpConnections = [connection]
        for provider in AIProvider.allCases {
            settings.provider = provider
            let arguments = AICommandClient.arguments(for: settings, output: directory.appendingPathComponent("reply.txt"))
            #expect(!arguments.joined().contains("MOCK_SECRET_VALUE"))
        }
        let data = try JSONEncoder().encode(settings)
        #expect(!String(decoding: data, as: UTF8.self).contains("MOCK_SECRET_VALUE"))
        #expect(try JSONDecoder().decode(AIReplySettings.self, from: data).mcpConnections.isEmpty)
    }

    @Test func stdioHandshakePaginationAndToolCall() async throws {
        let client = MCPClient(configuration: configuration())
        defer { client.close() }
        try await client.start()
        let tools = try await client.tools()
        #expect(tools.map(\.name) == ["lookup_knowledge", "unselected_write"])
        let result = try await client.call(tool: "lookup_knowledge", arguments: Data(#"{"query":"42"}"#.utf8))
        #expect(try MCPClient.text(from: result) == "Fixture data: ready")
    }

    @Test func discoveryDoesNotGrantToolsAndManualResultCanBecomeGuidance() async throws {
        let manager = PluginManager(storageURL: nil)
        let config = String(decoding: try JSONEncoder().encode(configuration()), as: UTF8.self)
        try manager.add(name: "Fixture", document: config)
        let id = try #require(manager.settings.connections.first?.id)
        await manager.inspect(id)
        #expect(manager.tools[id]?.count == 2)
        #expect(manager.activeConnections.isEmpty)
        #expect(manager.settings.connections[0].allowedTools.isEmpty)
        manager.allowTool("lookup_knowledge", connection: id, enabled: true)
        manager.setEnabled(id, true)
        #expect(manager.activeConnections.count == 1)
        await manager.call(id, tool: "lookup_knowledge", arguments: #"{"query":"42"}"#)
        #expect(manager.results[id] == "Fixture data: ready")
        var imported = ""
        manager.onGuideImported = { _, data in imported = String(decoding: data, as: UTF8.self) }
        try manager.importResult(id)
        #expect(imported == "Fixture data: ready")
        try manager.update(id, name: "Edited", document: config)
        #expect(manager.settings.connections[0].id == id)
        #expect(!manager.settings.connections[0].enabled)
        #expect(manager.settings.connections[0].allowedTools.isEmpty)
        #expect(manager.tools[id] == nil)
        manager.remove(id)
        #expect(manager.settings.connections.isEmpty)
    }

    @Test func providerProxyHidesAndRejectsUnselectedTools() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var connection = MCPPluginConnection(name: "Fixture", configuration: configuration())
        connection.enabled = true; connection.allowedTools = ["lookup_knowledge"]
        try MCPProviderConfiguration.prepare([connection], in: directory)
        let proxy = MCPClient(configuration: MCPServerConfiguration(command: MCPProviderConfiguration.proxyExecutable,
            args: ["--mcp-proxy", MCPProviderConfiguration.inputFile(connection, directory: directory).path]))
        defer { proxy.close() }
        try await proxy.start()
        #expect(try await proxy.tools().map(\.name) == ["lookup_knowledge"])
        #expect(try MCPClient.text(from: await proxy.call(tool: "lookup_knowledge", arguments: Data(#"{"query":"42"}"#.utf8))) == "Fixture data: ready")
        await #expect(throws: (any Error).self) { try await proxy.call(tool: "unselected_write", arguments: Data("{}".utf8)) }
    }

    @Test func pluginPersistenceKeepsOwnerOnlyPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let manager = PluginManager(storageURL: url)
        try manager.add(name: "Fixture", document: String(decoding: JSONEncoder().encode(configuration()), as: UTF8.self))
        let restored = PluginManager(storageURL: url)
        #expect(restored.settings.connections.count == 1)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func resultParserRejectsErrorsAndSupportsStructuredContent() throws {
        #expect(throws: (any Error).self) { try MCPClient.text(from: Data(#"{"isError":true,"content":[{"type":"text","text":"private failure"}]}"#.utf8)) }
        #expect(try MCPClient.text(from: Data(#"{"structuredContent":{"status":"ready"}}"#.utf8)).contains("ready"))
    }

    @Test func streamableHTTPUsesSessionAndHandlesSSE() async throws {
        MCPFixtureURLProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
            #expect(request.value(forHTTPHeaderField: "X-Tenant-ID") == "fixture")
            let rpc = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let method = rpc["method"] as! String
            if method == "notifications/initialized" { return (202, ["Content-Type": "application/json"], Data()) }
            let id = rpc["id"]!
            let result: [String: Any]
            if method == "initialize" { result = ["protocolVersion": "2025-11-25", "capabilities": ["tools": [:]], "serverInfo": ["name": "fixture", "version": "1"]] }
            else {
                #expect(request.value(forHTTPHeaderField: "Mcp-Session-Id") == "fixture-session")
                #expect(request.value(forHTTPHeaderField: "MCP-Protocol-Version") == "2025-11-25")
                result = ["tools": [["name": "lookup", "inputSchema": ["type": "object"]]]]
            }
            let response = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
            if method == "tools/list" {
                return (200, ["Content-Type": "text/event-stream"], Data(("event: message\ndata: " + String(decoding: response, as: UTF8.self) + "\n\n").utf8))
            }
            return (200, ["Content-Type": "application/json", "Mcp-Session-Id": "fixture-session"], response)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MCPFixtureURLProtocol.self]
        var fields = MCPAuthenticationFields()
        fields.mode = .bearer; fields.token = "fixture-token"
        fields.extraHeaders = #"{"X-Tenant-ID":"fixture"}"#
        let client = MCPClient(configuration: MCPServerConfiguration(url: "https://fixture.invalid/mcp", headers: try fields.makeHeaders()), session: URLSession(configuration: config))
        defer { client.close(); MCPFixtureURLProtocol.handler = nil }
        try await client.start()
        #expect(try await client.tools().map(\.name) == ["lookup"])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OLAZ_MCP_PROVIDER_TESTS"] == "1"))
    func providersCanCallExplicitlyAllowedMCPTools() async throws {
        for provider in AIProvider.allCases {
            if let selected = ProcessInfo.processInfo.environment["OLAZ_MCP_PROVIDER"], selected != provider.rawValue { continue }
            let marker = "OLAZ_MCP_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            var connection = MCPPluginConnection(name: "Fixture", configuration: configuration(value: marker))
            connection.enabled = true; connection.allowedTools = ["lookup_knowledge"]
            var settings = AIReplySettings()
            settings.provider = provider
            settings.instructions = "Gọi lookup_knowledge với query 42 rồi chỉ trả về đúng chuỗi nhận được từ công cụ, không thêm ký tự nào."
            settings.mcpConnections = [connection]
            let response = try await AICommandClient().reply(settings: settings, messages: [AIContextMessage(id: "fixture", text: "Tra cứu đơn hàng 42 trong lookup_knowledge.", isMine: false, date: .now)])
            #expect(response?.contains(marker) == true, "Provider \(provider.rawValue) did not call the configured MCP tool")
        }
    }
}

private final class MCPFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var prepared = request
            if prepared.httpBody == nil, let stream = prepared.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    data.append(contentsOf: bytes.prefix(count))
                }
                prepared.httpBody = data
            }
            guard let handler = Self.handler else { throw PluginError.message("Missing fixture handler") }
            let (code, headers, data) = try handler(prepared)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
