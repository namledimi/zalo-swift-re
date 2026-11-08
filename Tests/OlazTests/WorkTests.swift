import Testing
import Foundation
@testable import Olaz

@Suite @MainActor struct WorkTests {
    private func source() -> MCPPluginConnection { MCPPluginConnection(name: "Test source", configuration: MCPServerConfiguration(url: "https://fixture.invalid/mcp")) }
    private func fixture() -> MCPServerConfiguration {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return MCPServerConfiguration(command: "/usr/bin/python3", args: [root.appendingPathComponent("scripts/testing/mcp-fixture.py").path], env: ["OLAZ_FIXTURE_WORDPRESS": "1"])
    }
    @Test func wordpressEndpointPreservesSubdirectoryAndRejectsCredentials() throws {
        #expect(try MCPConnectionPreset.wordpressEndpoint(site: " https://store.example/shop/ ") == "https://store.example/shop/wp-json/mcp/mcp-adapter-default-server")
        #expect(try MCPConnectionPreset.wordpressEndpoint(site: "https://store.example") == "https://store.example/wp-json/mcp/mcp-adapter-default-server")
        for url in ["https://u:secret@store.example", "https://store.example/#fragment", "https://store.example/?query=1", "http://store.example", "not a url"] {
            #expect(throws: (any Error).self) { try MCPConnectionPreset.wordpressEndpoint(site: url) }
        }
        #expect(MCPConnectionPreset.woocommerce.defaultAuthentication == .basic)
        #expect(MCPConnectionPreset.facebookPages.defaultURL.isEmpty)
        #expect(MCPConnectionPreset.facebookAds.defaultURL == "https://mcp.facebook.com/ads")
    }
    @Test func newFieldsAreBackwardCompatibleAndRuntimeOwnerFlagIsNotSaved() throws {
        let data = try JSONEncoder().encode(source())
        let restored = try JSONDecoder().decode(MCPPluginConnection.self, from: data)
        #expect(restored.service == nil && restored.allowedAbilities == nil)
        var settings = AIReplySettings(); settings.forOwner = true
        let saved = try JSONEncoder().encode(settings)
        let legacy = try JSONDecoder().decode(AIReplySettings.self, from: saved)
        #expect(!legacy.forOwner && legacy.conversationPoliciesByAccount == nil)
        #expect(try AIReplyPrompt.make(settings: settings, messages: []).contains("chủ tài khoản"))
    }
    @Test func productMapperHandlesHoaWooAndMissingPriceWithoutInventingZero() throws {
        let hoa: [String: Any] = ["result": ["items": [["id": "p1", "name": "Hoa", "sku": "HB17", "minPrice": 300000, "maxPrice": 500000, "currency": "VND"], ["id": "p2", "name": "Thiếu giá", "price": ""]], "total": 148]]
        let parsed = WorkProduct.parse(hoa, source: source())
        #expect(parsed.products.count == 2 && parsed.total == 148)
        #expect(parsed.products[0].minPrice == 300000 && parsed.products[0].maxPrice == 500000)
        #expect(parsed.products[1].minPrice == nil && parsed.products[1].priceText == "Chưa có giá")
        let woo: [[String: Any]] = [["id": 42, "name": "Woo", "price": "19.95", "images": [["src": "https://images.example/p.jpg"]]], ["id": 43, "name": "Store API", "prices": ["price": "1995", "currency_minor_unit": 2, "currency_code": "USD"]]]
        let products = WorkProduct.parse(woo, source: source()).products
        #expect(products[0].minPrice == Decimal(string: "19.95") && products[0].imageURL != nil)
        #expect(products[0].currency == nil && products[0].priceText.contains("chưa rõ tiền tệ"))
        #expect(products[1].minPrice == Decimal(string: "19.95") && products[1].currency == "USD")
    }
    @Test func productMapperRejectsBadPricesAndImageURLsAndDeduplicates() {
        for price in ["", "12oops", "-1", "NaN", "1,200", " 10", "true"] { #expect(WorkProduct.decimal(price) == nil) }
        #expect(WorkProduct.decimal("0") == 0)
        for url in ["http://image.example/a.jpg", "https://u:secret@image.example/a", "file:///tmp/a", "https://image.example/#a"] { #expect(WorkProduct.httpsURL(url) == nil) }
        #expect(WorkProduct.parse([["id": "1", "name": "A"], ["id": "1", "name": "A"]], source: source()).products.count == 1)
    }
    @Test func payloadUnwrapsAdapterResultsAndRejectsErrors() throws {
        let result = try MCPData.payload(Data(#"{"content":[{"type":"text","text":"{\"success\":true,\"data\":{\"items\":[]}}"}]}"#.utf8))
        #expect((MCPData.unwrapped(result) as? [String: Any])?["items"] is [Any])
        #expect(throws: (any Error).self) { try MCPData.payload(Data(#"{"isError":true,"content":[]}"#.utf8)) }
        #expect(throws: (any Error).self) { try MCPData.payload(Data(#"{"structuredContent":{"success":false,"error":"failure"}}"#.utf8)) }
    }
    @Test func workStorePersistsAndScopesCustomersByAccount() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("data.json")
        let store = WorkStore(url: url)
        var a = store.customer(account: "a", conversationID: "c", name: "Customer A"); a.notes = "private A"; a.followUpAt = .now
        try store.save(a)
        var b = store.customer(account: "b", conversationID: "c", name: "Customer B"); b.notes = "private B"
        try store.save(b)
        try store.finishFollowUp(a.id)
        let restored = WorkStore(url: url)
        #expect(restored.database.customers.count == 2)
        #expect(restored.customer(account: "a", conversationID: "c", name: "").notes == "private A")
        #expect(restored.customer(account: "b", conversationID: "c", name: "").notes == "private B")
        #expect(restored.customer(account: "a", conversationID: "c", name: "").followUpAt == nil)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
    @Test func corruptWorkStoreIsNotOverwritten() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("corrupt".utf8).write(to: file)
        let store = WorkStore(url: file)
        #expect(throws: (any Error).self) { try store.save(CustomerWorkRecord(account: "a", conversationID: "c", name: "C")) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "corrupt")
    }
    @Test func orderDraftValidationAndRoundTrip() throws {
        let store = WorkStore(url: nil)
        var draft = WorkOrderDraft(account: "a", conversationID: "c", customerName: "C", lines: [])
        #expect(throws: (any Error).self) { try store.save(draft) }
        draft.lines = [WorkOrderLine(sourceID: UUID(), productID: "42", name: "Flower", unitPrice: 300000, currency: "VND")]
        try store.save(draft)
        #expect(draft.summary.contains("300000 VND"))
        #expect(try JSONDecoder().decode(WorkOrderDraft.self, from: JSONEncoder().encode(draft)) == draft)
        draft.lines[0].quantity = 0
        #expect(throws: (any Error).self) { try store.save(draft) }
    }
    @Test func wordpressAbilityGuardAndReadOnlyClassification() throws {
        try MCPToolAccess.validateAbilityCall(tool: MCPToolAccess.executeAbility, arguments: ["ability_name": "fixture/read"], allowed: ["fixture/read"])
        for args: [String: Any] in [[:], ["ability_name": "fixture/write"], ["ability_name": ["fixture/read"]]] {
            #expect(throws: (any Error).self) { try MCPToolAccess.validateAbilityCall(tool: MCPToolAccess.executeAbility, arguments: args, allowed: ["fixture/read"]) }
        }
        let write = MCPToolDescriptor(name: MCPToolAccess.executeAbility, description: "", inputSchema: Data("{}".utf8), annotations: Data(#"{"readOnlyHint":true}"#.utf8))
        #expect(!MCPToolAccess.isReadOnly(write))
        let destructive = MCPToolDescriptor(name: "search_products", description: "", inputSchema: Data("{}".utf8), annotations: Data(#"{"readOnlyHint":true,"destructiveHint":true}"#.utf8))
        #expect(!MCPToolAccess.isReadOnly(destructive))
        #expect(throws: (any Error).self) { try MCPToolAccess.validateAbilityCall(tool: MCPToolAccess.executeAbility, arguments: ["ability_name": "fixture/read"], allowed: nil) }
    }
    @Test func wordpressJSONPresetStillRequiresAbilityGrants() throws {
        let manager = PluginManager(storageURL: nil)
        try manager.add(name: "WP", document: String(decoding: JSONEncoder().encode(fixture()), as: UTF8.self), service: .wordpress)
        let connection = try #require(manager.settings.connections.first)
        #expect(connection.service == .wordpress && connection.allowedAbilities == [])
        manager.allowAbility("fixture/read", connection: connection.id, enabled: true)
        #expect(manager.settings.connections[0].allowedAbilities == ["fixture/read"])
        try manager.update(connection.id, name: "WP edited", document: String(decoding: JSONEncoder().encode(fixture()), as: UTF8.self), service: .wordpress)
        #expect(manager.settings.connections[0].allowedAbilities == [])
    }
    @Test func proxyBlocksUnselectedAbilityBeforeItReachesServer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var connection = MCPPluginConnection(name: "Fixture", configuration: fixture())
        connection.enabled = true; connection.allowedTools = [MCPToolAccess.executeAbility]; connection.allowedAbilities = ["fixture/read"]
        try MCPProviderConfiguration.prepare([connection], in: directory)
        let proxy = MCPClient(configuration: MCPServerConfiguration(command: MCPProviderConfiguration.proxyExecutable, args: ["--mcp-proxy", MCPProviderConfiguration.inputFile(connection, directory: directory).path]))
        defer { proxy.close() }
        try await proxy.start()
        await #expect(throws: (any Error).self) { try await proxy.call(tool: MCPToolAccess.executeAbility, arguments: Data(#"{"ability_name":"fixture/write","parameters":{}}"#.utf8)) }
        let result = try await proxy.call(tool: MCPToolAccess.executeAbility, arguments: Data(#"{"ability_name":"fixture/read","parameters":{}}"#.utf8))
        #expect((MCPData.unwrapped(try MCPData.payload(result)) as? [String: Any])?["ability"] as? String == "fixture/read")
    }
    @Test func assistantOnlyGetsSelectedReadAbilities() async throws {
        let manager = PluginManager(storageURL: nil)
        var connection = MCPPluginConnection(name: "WP fixture", configuration: fixture())
        connection.enabled = true; connection.service = .wordpress
        connection.allowedTools = [MCPToolAccess.executeAbility, MCPToolAccess.discoverAbilities, MCPToolAccess.abilityInfo]
        connection.allowedAbilities = ["fixture/read", "fixture/write"]
        manager.settings.connections = [connection]
        let runtime = try await manager.assistantConnections(selected: [connection.id], readOnly: true)
        #expect(runtime.first?.allowedAbilities == ["fixture/read"])
        #expect(runtime.first?.allowedTools.contains(MCPToolAccess.executeAbility) == true)
        #expect(manager.abilities[connection.id]?.first { $0.name == "fixture/read" }?.inputSchema.isEmpty == false)
        #expect(try await manager.assistantConnections(selected: [], readOnly: true).isEmpty)
    }
    @Test func perConversationModeAndSourcesOverrideGlobalSettings() async throws {
        let selected = source(), excluded = source()
        let controller = AIReplyController(storageURL: nil, generate: { settings, _ in
            #expect(settings.mode == .review)
            #expect(settings.mcpConnections.map(\.id) == [selected.id])
            return "Review this"
        }, debounce: { _ in })
        controller.activate(account: "a"); controller.select("c", enabled: true); controller.settings.enabled = true; controller.settings.mode = .automatic
        controller.pluginConnections = { [selected, excluded] }
        controller.setPolicy("c", AIConversationPolicy(mode: .review, connectionIDs: [selected.id]))
        var sends = 0; controller.sender = { _, _ in sends += 1; return true }; controller.validateTrigger = { _, _ in true }
        controller.receive(account: "a", conversation: "c", messages: [AIContextMessage(id: "new", text: "Hi", isMine: false, date: .now)])
        let deadline = Date.now.addingTimeInterval(1)
        while controller.busy.contains("c") && Date.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(controller.drafts["c"]?.text == "Review this" && sends == 0)
        controller.activate(account: "b")
        #expect(controller.policy("c").mode == nil && controller.policy("c").connectionIDs == nil)
    }
    @Test func pauseResumesWithoutAnsweringPausedHistoryAndManualTakeoverIsScoped() async throws {
        let controller = AIReplyController(storageURL: nil, generate: { _, _ in "Must not generate" }, debounce: { _ in })
        controller.activate(account: "a"); controller.select("c", enabled: true); controller.settings.enabled = true
        var policy = AIConversationPolicy(); policy.pausedUntil = .now.addingTimeInterval(0.03); policy.takeoverMinutes = 15
        controller.setPolicy("c", policy)
        #expect(controller.watchedConversations.isEmpty)
        let pausedMessage = AIContextMessage(id: "paused", text: "Hi", isMine: false, date: .now)
        controller.receive(account: "a", conversation: "c", messages: [pausedMessage])
        let deadline = Date.now.addingTimeInterval(1)
        while controller.policy("c").pausedUntil != nil && Date.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(controller.watchedConversations == ["c"])
        controller.receive(account: "a", conversation: "c", messages: [pausedMessage])
        #expect(controller.busy.isEmpty)
        controller.userWillSend(conversation: "c")
        #expect(controller.policy("c").pausedUntil != nil)
        controller.activate(account: nil)
    }
}
