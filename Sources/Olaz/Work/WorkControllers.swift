import Foundation
import Observation

struct WorkAssistantTurn: Identifiable {
    var id = UUID()
    var isUser: Bool
    var text: String
    var date = Date.now
    var tools: [String] = []
}

@MainActor @Observable final class WorkAssistantController {
    private(set) var turns: [WorkAssistantTurn] = []
    private(set) var busy = false
    private(set) var error: String?
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var lastSources: Set<UUID>?
    func clear() { cancel(); turns = []; error = nil }
    func cancel() { generation = UUID(); job?.cancel(); job = nil; busy = false }
    func ask(_ question: String, settings: AIReplySettings, plugins: PluginManager, sources: Set<UUID>) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !question.isEmpty, question.count <= 4000 else { return }
        if lastSources != sources { clear() }
        lastSources = sources
        turns.append(WorkAssistantTurn(isUser: true, text: question))
        if turns.count > 60 { turns.removeFirst(turns.count - 60) }
        busy = true; error = nil
        let token = UUID(); generation = token
        job = Task { [weak self] in
            guard let self else { return }
            defer { if generation == token { busy = false; job = nil } }
            do {
                var runtime = settings
                runtime.forOwner = true; runtime.contextCount = 30
                runtime.mcpConnections = try await plugins.assistantConnections(selected: sources, readOnly: true)
                let context = turns.suffix(30).map { AIContextMessage(id: $0.id.uuidString, text: $0.text, isMine: !$0.isUser, date: $0.date) }
                let reply = try await AICommandClient().replyWithDiagnostics(settings: runtime, messages: context)
                try Task.checkCancellation()
                guard generation == token else { return }
                turns.append(WorkAssistantTurn(isUser: false, text: reply.text ?? "Trợ lý chưa có câu trả lời.", tools: reply.toolCalls ?? []))
            } catch is CancellationError {} catch { if generation == token { self.error = error.localizedDescription } }
        }
    }
}

@MainActor @Observable final class WorkProductsController {
    private(set) var products: [WorkProduct] = []
    private(set) var total: Int?
    private(set) var busy = false
    private(set) var error: String?
    private(set) var sourceLabel = ""
    @ObservationIgnored private var generation = UUID()
    func clear() { generation = UUID(); products = []; total = nil; error = nil; sourceLabel = "" }

    func search(sourceID: UUID, tool: String, arguments: String, plugins: PluginManager) async {
        guard !busy, let source = plugins.settings.connections.first(where: { $0.id == sourceID }) else { return }
        busy = true; error = nil
        products = []; total = nil
        let token = UUID(); generation = token
        defer { busy = false }
        do {
            guard let data = arguments.data(using: .utf8), data.count <= 100_000 else { throw PluginError.message("Tham số tìm kiếm tối đa 100 KB.") }
            let parameters = try MCPClient.object(data)
            let result = try await plugins.executeGranted(sourceID, tool: tool, arguments: parameters)
            guard generation == token else { return }
            let parsed = WorkProduct.parse(try MCPData.payload(result), source: source)
            products = parsed.products; total = parsed.total; sourceLabel = source.name
            if products.isEmpty { error = "Chưa có sản phẩm trong phản hồi này. Kiểm tra bộ lọc, trang kết quả và cấu trúc dữ liệu của nguồn." }
        } catch { if generation == token { self.error = error.localizedDescription } }
    }

    func details(_ product: WorkProduct, plugins: PluginManager) async {
        guard !busy, let source = plugins.settings.connections.first(where: { $0.id == product.sourceID }),
              source.allowedTools.contains("get_product"), let tool = plugins.tools[source.id]?.first(where: { $0.name == "get_product" }) else { return }
        busy = true; error = nil; defer { busy = false }
        do {
            let schema = try MCPClient.object(tool.inputSchema)
            let properties = schema["properties"] as? [String: Any] ?? [:]
            guard let key = ["id", "productId", "product_id"].first(where: { properties[$0] != nil }) else { throw PluginError.message("Schema get_product chưa có trường ID được hỗ trợ. Có thể gọi thủ công ở Kết nối.") }
            let field = properties[key] as? [String: Any] ?? [:]
            let identifier: Any
            if field["type"] as? String == "integer" {
                guard let number = Int(product.productID) else { throw PluginError.message("Nguồn yêu cầu ID sản phẩm dạng số.") }
                identifier = number
            } else { identifier = product.productID }
            let result = try await plugins.executeGranted(source.id, tool: "get_product", arguments: [key: identifier])
            if var detail = WorkProduct.parse(try MCPData.payload(result), source: source).products.first,
               detail.productID == product.productID,
               let index = products.firstIndex(where: { $0.id == product.id }) {
                if detail.minPrice == nil { detail.minPrice = product.minPrice; detail.maxPrice = product.maxPrice }
                if detail.currency == nil { detail.currency = product.currency }
                if detail.sku.isEmpty { detail.sku = product.sku }
                products[index] = detail
            } else { error = "Nguồn chưa trả chi tiết sản phẩm theo cấu trúc được hỗ trợ." }
        } catch { self.error = error.localizedDescription }
    }
}
