import SwiftUI

struct PluginListColumn: View {
    @Environment(ShellModel.self) private var shell
    var body: some View {
        @Bindable var shell = shell
        List(selection: $shell.pluginDestination) {
            Section("Kết nối") {
                Label("Kết nối MCP", systemImage: "puzzlepiece.extension").tag(PluginDestination.connections)
            }
            Section("Công việc") {
                Label("Trợ lý công việc", systemImage: "sparkles").tag(PluginDestination.assistant)
                Label("Sản phẩm và báo giá", systemImage: "shippingbox").tag(PluginDestination.products)
                Label("Khách hàng và công việc", systemImage: "checklist").tag(PluginDestination.work)
                Label("Kho hướng dẫn", systemImage: "books.vertical").tag(PluginDestination.knowledge)
            }
        }
        .navigationTitle("Plugin")
    }
}

struct PluginDetailColumn: View {
    @Environment(ZaloEngine.self) private var engine
    @Environment(ShellModel.self) private var shell

    var body: some View {
        Group {
            switch shell.pluginDestination {
            case .connections: MCPConnectionsView()
            case .assistant: WorkAssistantView()
            case .products: WorkProductsView()
            case .work: WorkRecordsView()
            case .knowledge: WorkKnowledgeView()
            }
        }
    }
}

private struct MCPConnectionsView: View {
    @Environment(ZaloEngine.self) private var engine
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsTab.selectionKey) private var settingsTab = SettingsTab.general
    @State private var newPreset: MCPConnectionPreset?

    private var connections: [MCPPluginConnection] {
        engine.plugins.settings.connections
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Kết nối MCP").font(.title2.bold())
                        Text("Thêm server MCP local (stdio) hoặc Streamable HTTP. Chọn công cụ được phép dùng rồi bật kết nối cho trợ lý AI.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu("Thêm kết nối…", systemImage: "plus") {
                        ForEach(MCPConnectionPreset.allCases) { item in
                            Button(item.title) { newPreset = item }
                        }
                    }
                }
                HStack(alignment: .top) {
                    Text("Công cụ được cấp cho các hội thoại đã bật AI, dùng cùng hướng dẫn và chế độ phản hồi hiện tại.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cài đặt AI…") { settingsTab = .ai; openSettings() }
                }
                if let error = engine.plugins.storageError { Text(error).foregroundStyle(.red) }
                if connections.isEmpty {
                    ContentUnavailableView("Chưa có MCP server", systemImage: "puzzlepiece.extension",
                                           description: Text("Thêm địa chỉ MCP hoặc cấu hình của server bạn muốn kết nối. Server cần sẵn sàng và được xác thực nếu có yêu cầu."))
                }
                ForEach(connections) { connection in
                    MCPConnectionCard(connection: connection)
                }
            }
            .padding(24)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Kết nối MCP")
        .sheet(item: $newPreset) { MCPConnectionEditor(preset: $0) }
    }
}

private struct MCPConnectionCard: View {
    let connection: MCPPluginConnection
    @Environment(ZaloEngine.self) private var engine
    @State private var selectedTool = ""
    @State private var arguments = "{}"
    @State private var showEdit = false
    @State private var error: String?

    var body: some View {
        let plugins = engine.plugins
        let id = connection.id
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(connection.name, systemImage: "puzzlepiece.extension")
                    .font(.headline)
                Spacer()
                Button("Sửa…") { showEdit = true }
                Button("Gỡ") { plugins.remove(id) }
            }
            Toggle("Cho trợ lý AI dùng kết nối này", isOn: Binding(get: { connection.enabled }, set: { plugins.setEnabled(id, $0) }))
            if connection.enabled && connection.allowedTools.isEmpty {
                Text("Chưa có công cụ được cấp. Tải danh sách và chọn công cụ để trợ lý dùng kết nối này.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(connection.configuration.url != nil ? "Streamable HTTP" : "MCP local · \(connection.configuration.command ?? "")")
                .font(.caption).foregroundStyle(.secondary)
            if connection.oauth != nil {
                HStack {
                    Label("OAuth qua trình duyệt", systemImage: "person.badge.key").font(.caption)
                    Spacer()
                    if plugins.authenticating.contains(id) {
                        Button("Hủy đăng nhập") { plugins.cancelOAuth(id) }
                    } else {
                        Button("Đăng nhập OAuth…") { plugins.startOAuth(id) }.disabled(plugins.busy.contains(id))
                    }
                }
            }
            HStack {
                Button("Kiểm tra và tải công cụ") { Task { await plugins.inspect(id) } }.disabled(plugins.busy.contains(id))
                if plugins.busy.contains(id) { ProgressView().controlSize(.small) }
            }
            Text(plugins.status[id] ?? "Chưa kiểm tra kết nối").font(.caption).foregroundStyle(.secondary)
            if connection.service?.isWordPress == true || connection.allowedTools.contains(MCPToolAccess.executeAbility) || plugins.tools[id]?.contains(where: { $0.name == MCPToolAccess.executeAbility }) == true {
                WordPressAbilitiesView(connection: connection)
            }

            if let tools = plugins.tools[id] {
                DisclosureGroup("Công cụ được cấp cho AI (\(connection.allowedTools.count)/\(tools.count))") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Chỉ công cụ bạn chọn mới được cấp cho AI. Với nguồn dữ liệu, chọn công cụ đọc và tìm kiếm.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(tools) { tool in
                            Toggle(isOn: Binding(get: { connection.allowedTools.contains(tool.name) }, set: { plugins.allowTool(tool.name, connection: id, enabled: $0) })) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(tool.name).font(.system(.callout, design: .monospaced))
                                    if !tool.description.isEmpty { Text(tool.description).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                                }
                            }
                        }
                    }.padding(.top, 8)
                }
                if !connection.allowedTools.isEmpty {
                    Divider()
                    Text("Lấy dữ liệu từ công cụ").font(.subheadline.bold())
                    Picker("Công cụ", selection: $selectedTool) {
                        Text("Chọn công cụ…").tag("")
                        ForEach(tools.filter { connection.allowedTools.contains($0.name) }) { Text($0.name).tag($0.name) }
                    }
                    if let tool = tools.first(where: { $0.name == selectedTool }) {
                        DisclosureGroup("Cấu trúc tham số JSON") {
                            Text(String(decoding: tool.inputSchema, as: UTF8.self))
                                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    TextEditor(text: $arguments).font(.system(size: 12, design: .monospaced)).frame(height: 100)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    Button("Gọi công cụ") { Task { await plugins.call(id, tool: selectedTool, arguments: arguments) } }
                        .disabled(selectedTool.isEmpty || plugins.busy.contains(id))
                }
            } else if !connection.allowedTools.isEmpty {
                Text("Đã cấp \(connection.allowedTools.count) công cụ. Tải danh sách để xem hoặc thay đổi quyền.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let result = plugins.results[id] {
                ScrollView { Text(result).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 220)
                Button("Dùng làm dữ liệu hướng dẫn AI") {
                    do { try plugins.importResult(id) } catch { self.error = error.localizedDescription }
                }
            }
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.separator))
        .sheet(isPresented: $showEdit) { MCPConnectionEditor(connection: connection) }
        .alert("Chưa thêm được dữ liệu", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
}

private struct MCPConnectionEditor: View {
    var connection: MCPPluginConnection?
    var preset: MCPConnectionPreset = .generic
    @Environment(ZaloEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var document = ""
    @State private var authentication = MCPAuthenticationFields()
    @State private var error: String?
    @State private var service = MCPConnectionPreset.generic
    @State private var siteURL = ""

    private var remoteAddress: String {
        let text = document.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? JSONDecoder().decode(String.self, from: Data(text.utf8))) ?? text
    }

    private var usesAuthenticationForm: Bool {
        remoteAddress.lowercased().hasPrefix("https://") || remoteAddress.lowercased().hasPrefix("http://")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(connection == nil ? "Thêm kết nối MCP" : "Sửa kết nối MCP").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("Tên kết nối", text: $name).textFieldStyle(.roundedBorder)
                    Picker("Loại nguồn", selection: $service) {
                        ForEach(MCPConnectionPreset.allCases) { Text($0.title).tag($0) }
                    }
                    Text(service.help).font(.callout).foregroundStyle(.secondary)
                    if service.isWordPress {
                        HStack {
                            TextField("https://website-cua-ban", text: $siteURL).textFieldStyle(.roundedBorder)
                            Button("Tạo endpoint") {
                                do { document = try MCPConnectionPreset.wordpressEndpoint(site: siteURL) }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                    Text("Địa chỉ MCP hoặc cấu hình JSON").font(.subheadline.weight(.semibold))
                    Text("Dán URL của server, ví dụ https://server.example/mcp, rồi chọn xác thực bên dưới. Cấu hình JSON vẫn hỗ trợ command/args/env hoặc url/headers.")
                        .font(.callout).foregroundStyle(.secondary)
                    TextEditor(text: $document).font(.system(size: 12, design: .monospaced))
                        .frame(height: usesAuthenticationForm ? 65 : 170)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                        .accessibilityLabel("Địa chỉ MCP hoặc cấu hình JSON")
                    if usesAuthenticationForm {
                        Divider()
                        MCPAuthenticationForm(fields: $authentication, serverURL: URL(string: remoteAddress))
                    }
                }.padding(2)
            }
            .frame(maxHeight: 510)
            Text("Kết nối mới hoặc vừa sửa sẽ ở trạng thái tắt. Kiểm tra công cụ rồi chọn quyền trước khi cấp cho AI.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Hủy") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(connection == nil ? "Thêm" : "Lưu") {
                    do {
                        var auth = usesAuthenticationForm ? authentication : nil
                        auth?.service = service
                        if let connection { try engine.plugins.update(connection.id, name: name, document: document, authentication: auth, service: service) }
                        else { try engine.plugins.add(name: name, document: document, authentication: auth, service: service) }
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || document.isEmpty)
            }
        }
        .padding(24).frame(width: 560)
        .onChange(of: document) { _, _ in error = nil }
        .onChange(of: authentication) { _, _ in error = nil }
        .onChange(of: service) { _, value in
            authentication.service = value
            if connection == nil {
                authentication.mode = value.defaultAuthentication
                if !value.defaultURL.isEmpty { document = value.defaultURL }
            }
        }
        .onAppear {
            service = connection?.service ?? preset
            authentication.service = service
            name = connection?.name ?? (preset == .generic ? "MCP" : preset.title)
            if let connection, let url = connection.configuration.url {
                document = url
                authentication = MCPAuthenticationFields(headers: connection.configuration.headers ?? [:])
                authentication.service = service
                if let oauth = connection.oauth {
                    authentication.mode = .oauth
                    authentication.oauthClientID = oauth.clientID
                    authentication.oauthScopes = oauth.scopes
                    authentication.oauthCallbackPort = String(oauth.callbackPort)
                    authentication.oauthPublicRedirectURI = oauth.publicRedirectURI ?? ""
                }
            } else if let connection, let data = try? JSONEncoder().encode(connection.configuration),
               let object = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                document = String(decoding: pretty, as: UTF8.self)
            } else {
                document = preset.defaultURL
                authentication.mode = preset.defaultAuthentication
            }
        }
    }
}

private struct MCPAuthenticationForm: View {
    @Binding var fields: MCPAuthenticationFields
    var serverURL: URL?
    @State private var showOAuthAdvanced = false

    private var isMetaMCP: Bool {
        serverURL?.host?.lowercased() == "mcp.facebook.com" && serverURL?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "ads"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Xác thực", selection: $fields.mode) {
                ForEach(MCPAuthenticationMode.allCases) { Text($0.title).tag($0) }
            }
            switch fields.mode {
            case .none:
                Text("Chọn kiểu xác thực theo hướng dẫn của server MCP nếu server yêu cầu đăng nhập.")
                    .font(.caption).foregroundStyle(.secondary)
            case .bearer:
                LabeledContent("Token") {
                    SecureField("Nhập Bearer token", text: $fields.token)
                        .accessibilityLabel("Bearer token")
                }
                Text("Dán token do server cấp. Olaz tự thêm Authorization: Bearer.")
                    .font(.caption).foregroundStyle(.secondary)
            case .apiKey:
                LabeledContent("Tên header") {
                    TextField("Ví dụ: X-API-Key", text: $fields.headerName)
                        .accessibilityLabel("Tên header API key")
                }
                LabeledContent("API key") {
                    SecureField("Nhập API key", text: $fields.token)
                        .accessibilityLabel("API key")
                }
                Text("Dùng đúng tên header trong hướng dẫn của server MCP.")
                    .font(.caption).foregroundStyle(.secondary)
            case .basic:
                LabeledContent("Tên đăng nhập") {
                    TextField(fields.service?.isWordPress == true ? "Username WordPress" : "Tài khoản MCP", text: $fields.username)
                        .accessibilityLabel("Tên đăng nhập MCP")
                }
                LabeledContent(fields.service?.isWordPress == true ? "Application Password" : "Mật khẩu") {
                    SecureField(fields.service?.isWordPress == true ? "Application Password WordPress" : "Mật khẩu MCP", text: $fields.password)
                        .accessibilityLabel(fields.service?.isWordPress == true ? "Application Password WordPress" : "Mật khẩu MCP")
                }
                Text(fields.service?.isWordPress == true ? "Tạo Application Password trong WordPress → Users → Profile. Không dùng mật khẩu đăng nhập hoặc WooCommerce Consumer Secret." : "Chỉ dùng khi server hỗ trợ HTTP Basic. Tài khoản đăng nhập website có thể không dùng được ở đây.")
                    .font(.caption).foregroundStyle(.secondary)
            case .oauth:
                Text("Lưu kết nối rồi chọn Đăng nhập OAuth… trên thẻ MCP. Olaz mở trình duyệt để bạn đăng nhập và cấp quyền trên website của nhà cung cấp.")
                    .font(.callout).foregroundStyle(.secondary)
                if isMetaMCP {
                    Text("Kết nối Meta Ads bằng ứng dụng của bạn: nhập Meta App ID, cấu hình quyền MCP và đăng ký đúng Redirect URI bên dưới trong ứng dụng Meta. Chỉ URL MCP chưa đủ khi Meta từ chối đăng ký tự động.")
                        .font(.callout).foregroundStyle(.secondary)
                    Link("Mở Meta for Developers để cấu hình ứng dụng", destination: URL(string: "https://developers.facebook.com/apps/")!)
                        .font(.callout)
                }
                DisclosureGroup("Cấu hình OAuth nâng cao (tùy server)", isExpanded: $showOAuthAdvanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent(isMetaMCP ? "Meta App ID" : "Client ID") {
                            TextField(isMetaMCP ? "Nhập App ID đã đăng ký với Meta" : "Để trống để đăng ký tự động", text: $fields.oauthClientID)
                                .accessibilityLabel("OAuth Client ID")
                        }
                        LabeledContent("Client Secret") {
                            SecureField("Tùy chọn; để trống giữ secret đã lưu", text: $fields.oauthClientSecret)
                                .accessibilityLabel("OAuth Client Secret")
                        }
                        LabeledContent("Scope") {
                            TextField("Tự lấy từ server nếu để trống", text: $fields.oauthScopes)
                                .accessibilityLabel("OAuth scope")
                        }
                        LabeledContent("Cổng nhận trên máy") {
                            TextField("8765", text: $fields.oauthCallbackPort)
                                .accessibilityLabel("Cổng callback OAuth")
                        }
                        LabeledContent("Callback HTTPS") {
                            TextField("Để trống nếu server hỗ trợ localhost", text: $fields.oauthPublicRedirectURI)
                                .accessibilityLabel("Callback OAuth HTTPS công khai")
                        }
                        Text("Redirect URI: \(fields.oauthPublicRedirectURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "http://127.0.0.1:\(fields.oauthCallbackPort)/callback" : fields.oauthPublicRedirectURI.trimmingCharacters(in: .whitespacesAndNewlines))")
                            .font(.caption.monospaced()).textSelection(.enabled)
                        Text("Nếu server chỉ nhận HTTPS, nhập URL tunnel trỏ về http://127.0.0.1:\(fields.oauthCallbackPort). Tunnel cần giữ nguyên đường dẫn callback và chạy trong lúc đăng nhập. Đăng ký chính xác cùng URL HTTPS ở server.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Nếu server không cho đăng ký tự động, đăng ký client với redirect URI này rồi nhập Client ID. Các scope cách nhau bằng dấu cách.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }
            case .custom:
                Text("Nhập các header do server yêu cầu dưới dạng JSON. Nội dung có thể chứa thông tin bí mật.")
                    .font(.caption).foregroundStyle(.secondary)
                headersEditor
            }
            if fields.mode == .bearer || fields.mode == .apiKey || fields.mode == .basic || fields.mode == .oauth {
                DisclosureGroup("Header bổ sung (nếu server yêu cầu)") { headersEditor.padding(.top, 8) }
            }
            Text(fields.mode == .oauth ? "Token OAuth và Client Secret được lưu trong Keychain trên máy này." : "Token và mật khẩu được lưu cùng kết nối trên máy này.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .textFieldStyle(.roundedBorder)
        .onAppear { if fields.mode == .oauth && isMetaMCP { showOAuthAdvanced = true } }
        .onChange(of: fields.mode) { _, mode in if mode == .oauth && isMetaMCP { showOAuthAdvanced = true } }
        .onChange(of: isMetaMCP) { _, isMeta in if isMeta && fields.mode == .oauth { showOAuthAdvanced = true } }
    }

    private var headersEditor: some View {
        TextEditor(text: $fields.extraHeaders).font(.system(size: 12, design: .monospaced))
            .frame(height: 90)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            .accessibilityLabel("Header xác thực JSON")
    }
}
