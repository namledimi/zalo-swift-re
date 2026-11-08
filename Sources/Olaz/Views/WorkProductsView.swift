import SwiftUI

struct WorkProductsView: View {
    @Environment(ZaloEngine.self) private var engine
    @Environment(ShellModel.self) private var shell
    @State private var sourceID = ""
    @State private var tool = ""
    @State private var ability = ""
    @State private var query = ""
    @State private var arguments = "{}"
    @State private var budget = ""
    @State private var target = ""
    @State private var imageProduct: WorkProduct?
    @State private var order: WorkOrderDraft?
    @State private var error: String?
    private var source: MCPPluginConnection? { engine.plugins.settings.connections.first { $0.id.uuidString == sourceID } }
    private var catalog: [MCPToolDescriptor] { source.flatMap { engine.plugins.tools[$0.id] } ?? [] }
    private var productTools: [MCPToolDescriptor] {
        catalog.filter { source?.allowedTools.contains($0.name) == true && ($0.name.contains("product") && MCPToolAccess.isReadOnly($0) || $0.name == MCPToolAccess.executeAbility) }
    }
    private var availableAbilities: [MCPAbilityDescriptor] {
        guard let source else { return [] }
        return (engine.plugins.abilities[source.id] ?? []).filter { source.allowedAbilities?.contains($0.name) == true && $0.readOnly && $0.name.contains("product") }
    }
    private var filtered: [WorkProduct] {
        guard let limit = WorkProduct.decimal(budget), !budget.isEmpty else { return engine.workProducts.products }
        return engine.workProducts.products.filter { $0.minPrice.map { $0 <= limit } == true }
    }
    var body: some View {
        let model = engine.workProducts
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Sản phẩm và báo giá").font(.title2.bold())
                Text("Dữ liệu lấy từ MCP đã cấp quyền. Chèn báo giá tạo bản nháp; ảnh chỉ gửi khi bạn xác nhận người nhận.").font(.callout).foregroundStyle(.secondary)
                Picker("Nguồn", selection: $sourceID) {
                    Text("Chọn nguồn MCP…").tag("")
                    ForEach(engine.plugins.settings.connections) { Text($0.name).tag($0.id.uuidString) }
                }.disabled(model.busy)
                Button("Tải công cụ của nguồn") { Task { await loadSource() } }.disabled(source == nil || model.busy)
                Picker("Công cụ sản phẩm", selection: $tool) {
                    Text("Chọn công cụ đã cấp…").tag("")
                    ForEach(productTools) { Text($0.name).tag($0.name) }
                }
                if tool == MCPToolAccess.executeAbility {
                    Picker("Ability đọc sản phẩm", selection: $ability) {
                        Text("Chọn ability đã cấp…").tag("")
                        ForEach(availableAbilities) { Text($0.label + " · " + $0.name).tag($0.name) }
                    }
                    Text("Tham số bên dưới là parameters của ability. Tải và cấp quyền ability ở Kết nối trước khi dùng.").font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("Từ khóa sản phẩm (nếu công cụ có query/search)", text: $query)
                }
                DisclosureGroup("Tham số JSON của nguồn") {
                    TextEditor(text: $arguments).font(.system(.caption, design: .monospaced)).frame(height: 90)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    if let schema = tool == MCPToolAccess.executeAbility ? availableAbilities.first(where: { $0.name == ability })?.inputSchema : catalog.first(where: { $0.name == tool })?.inputSchema {
                        Text(String(decoding: schema, as: UTF8.self)).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    }
                }
                HStack {
                    Button("Tra sản phẩm") { Task { await search() } }.buttonStyle(.borderedProminent)
                        .disabled(source == nil || tool.isEmpty || model.busy || tool == MCPToolAccess.executeAbility && ability.isEmpty)
                    if model.busy { ProgressView().controlSize(.small) }
                    TextField("Giá tối đa để lọc kết quả đã tải", text: $budget)
                }
                if !budget.isEmpty && WorkProduct.decimal(budget) == nil { Text("Giá tối đa cần là số, ví dụ 500000.").foregroundStyle(.red).font(.caption) }
                WorkTargetPicker(target: $target)
                if let error = error ?? model.error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
                Text("Đã tải \(model.products.count)\(model.total.map { "/\($0)" } ?? "") sản phẩm · Hiển thị \(filtered.count). Bộ lọc giá áp dụng trên trang đã tải.")
                    .font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), alignment: .top)], alignment: .leading, spacing: 14) {
                    ForEach(filtered) { product in productCard(product) }
                }
            }.padding(22)
        }
        .onAppear { if target.isEmpty { target = shell.selection ?? "" }; if sourceID.isEmpty { sourceID = engine.plugins.activeConnections.first?.id.uuidString ?? "" } }
        .onChange(of: sourceID) { _, _ in tool = ""; ability = ""; arguments = "{}"; engine.workProducts.clear() }
        .onChange(of: engine.plugins.settings) { _, _ in engine.workProducts.clear() }
        .sheet(item: $imageProduct) { product in ProductImageSendSheet(product: product, conversationID: target) }
        .sheet(item: $order) { draft in WorkOrderEditor(draft: draft) }
    }
    private func productCard(_ product: WorkProduct) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if let url = product.imageURL {
                AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { Image(systemName: "photo").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity).frame(height: 135)
            } else {
                Label("Chưa có ảnh từ nguồn", systemImage: "photo").font(.caption).foregroundStyle(.secondary).frame(height: 60)
            }
            Text(product.name).font(.headline)
            if !product.sku.isEmpty { Text(product.sku).font(.caption).foregroundStyle(.secondary) }
            Text(product.priceText).font(.callout.weight(.semibold))
            Text(product.sourceName + " · " + product.fetchedAt.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Sao chép") { WorkActions.copy(product.quote) }
                Button("Chèn báo giá") { WorkActions.insert(product.quote, target: target, engine: engine, shell: shell) }.disabled(target.isEmpty)
            }.font(.caption)
            HStack {
                if source?.allowedTools.contains("get_product") == true {
                    Button("Tải chi tiết / ảnh") { Task { await engine.workProducts.details(product, plugins: engine.plugins) } }.disabled(engine.workProducts.busy)
                }
                if product.imageURL != nil { Button("Gửi ảnh…") { imageProduct = product }.disabled(target.isEmpty) }
            }.font(.caption)
            Button("Lập đơn nháp…") {
                guard let account = engine.profile?.userId, let customer = engine.visibleConversations.first(where: { $0.id == target }) else { return }
                order = WorkOrderDraft(account: account, conversationID: target, customerName: customer.displayName,
                    lines: [WorkOrderLine(sourceID: product.sourceID, productID: product.productID, name: product.name, unitPrice: product.minPrice, currency: product.currency)])
            }.disabled(target.isEmpty || engine.profile == nil).font(.caption)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
    }
    private func loadSource() async {
        guard let source else { return }
        await engine.plugins.inspect(source.id)
        if source.service?.isWordPress == true { await engine.plugins.loadAbilities(source.id) }
        tool = productTools.first(where: { $0.name == "search_products" })?.name ?? productTools.first?.name ?? ""
        ability = availableAbilities.first?.name ?? ""
    }
    private func search() async {
        guard let source else { return }
        error = nil
        do {
            var parameters = try MCPClient.object(Data(arguments.utf8))
            if tool == MCPToolAccess.executeAbility { parameters = ["ability_name": ability, "parameters": parameters] }
            else if !query.isEmpty, let descriptor = catalog.first(where: { $0.name == tool }) {
                let schema = try MCPClient.object(descriptor.inputSchema)
                let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
                guard let key = ["query", "search", "s"].first(where: { properties[$0]?["type"] as? String == "string" }) else {
                    throw PluginError.message("Công cụ dùng tham số khác query/search. Nhập bộ lọc theo schema trong phần JSON và để từ khóa trống.")
                }
                parameters[key] = query
            }
            let text = String(decoding: try JSONSerialization.data(withJSONObject: parameters), as: UTF8.self)
            await engine.workProducts.search(sourceID: source.id, tool: tool, arguments: text, plugins: engine.plugins)
        } catch { self.error = error.localizedDescription }
    }
}

private struct ProductImageSendSheet: View {
    let product: WorkProduct
    let conversationID: String
    @Environment(ZaloEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var sending = false
    @State private var pending = false
    @State private var accountAtOpen: String?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Gửi ảnh sản phẩm").font(.title2.bold())
            Text(product.name)
            Text("Người nhận: " + (engine.visibleConversations.first { $0.id == conversationID }?.displayName ?? "Hội thoại không còn khả dụng"))
            if let url = product.imageURL {
                AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { ProgressView() }.frame(height: 250)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Hủy") { dismiss() }.disabled(sending)
                Spacer()
                if sending { ProgressView().controlSize(.small) }
                Button("Xác nhận gửi ảnh") { Task { await send() } }.buttonStyle(.borderedProminent).disabled(sending || pending || product.imageURL == nil)
            }
        }.padding(24).frame(width: 490)
            .onAppear { if accountAtOpen == nil { accountAtOpen = engine.profile?.userId } }
    }
    private func send() async {
        guard let url = product.imageURL, let account = accountAtOpen, account == engine.profile?.userId else { error = "Tài khoản đã thay đổi. Chọn lại người nhận."; return }
        sending = true; defer { sending = false }
        do {
            let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 35
            let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
            let (bytes, response) = try await session.bytes(from: url)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.scheme == "https",
                  let mime = http.mimeType, mime.hasPrefix("image/") else { throw PluginError.message("Không tải được ảnh HTTPS hợp lệ từ nguồn.") }
            var data = Data()
            for try await byte in bytes { guard data.count < 10_000_000 else { throw PluginError.message("Ảnh vượt quá 10 MB.") }; data.append(byte) }
            guard engine.profile?.userId == account, engine.visibleConversations.contains(where: { $0.id == conversationID }) else { throw PluginError.message("Tài khoản hoặc hội thoại đã thay đổi. Chọn lại người nhận.") }
            let ext = mime.contains("png") ? "png" : mime.contains("webp") ? "webp" : mime.contains("gif") ? "gif" : "jpg"
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
            guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw PluginError.message("Không chuẩn bị được ảnh gửi.") }
            defer { try? FileManager.default.removeItem(at: file) }
            engine.aiReply.userWillSend(conversation: conversationID)
            let outcome = await engine.sendMedia([file], to: conversationID)
            switch outcome {
            case .done: dismiss()
            case .cancelled: self.error = "Zalo đã hủy thao tác gửi ảnh."
            case .failed(let message): self.error = message
            case .pending(let message): pending = true; self.error = message + " Đóng cửa sổ và kiểm tra hội thoại trước khi thao tác tiếp."
            }
        } catch { self.error = error.localizedDescription }
    }
}
