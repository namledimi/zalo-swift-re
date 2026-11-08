import Foundation

enum MCPAuthenticationMode: String, CaseIterable, Identifiable, Sendable {
    case none, bearer, apiKey, basic, oauth, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "Không thêm xác thực"
        case .bearer: "Bearer token"
        case .apiKey: "API key trong header"
        case .basic: "Tên đăng nhập / mật khẩu (HTTP Basic)"
        case .oauth: "Đăng nhập qua trình duyệt (OAuth)"
        case .custom: "Header tùy chỉnh (JSON)"
        }
    }
}

/// Editable authentication values. Only the resulting HTTP headers are passed to the existing MCP transport.
struct MCPAuthenticationFields: Equatable, Sendable {
    var mode: MCPAuthenticationMode = .none
    var token = ""
    var headerName = "X-API-Key"
    var username = ""
    var password = ""
    var extraHeaders = "{}"
    var oauthClientID = ""
    var oauthClientSecret = ""
    var oauthScopes = ""
    var oauthCallbackPort = "8765"
    var oauthPublicRedirectURI = ""
    var service: MCPConnectionPreset?

    init(headers: [String: String] = [:]) {
        guard !headers.isEmpty else { return }
        var remaining = headers
        if let auth = headers.first(where: { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame }) {
            if auth.value.lowercased().hasPrefix("bearer ") {
                mode = .bearer
                token = String(auth.value.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                remaining.removeValue(forKey: auth.key)
            } else if auth.value.lowercased().hasPrefix("basic "),
                      let data = Data(base64Encoded: String(auth.value.dropFirst(6))),
                      let pair = String(data: data, encoding: .utf8), let colon = pair.firstIndex(of: ":") {
                mode = .basic
                username = String(pair[..<colon])
                password = String(pair[pair.index(after: colon)...])
                remaining.removeValue(forKey: auth.key)
            } else { mode = .custom }
        } else if headers.count == 1, let entry = headers.first {
            mode = .apiKey
            headerName = entry.key
            token = entry.value
            remaining = [:]
        } else { mode = .custom }
        if let data = try? JSONSerialization.data(withJSONObject: remaining, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            extraHeaders = String(decoding: data, as: UTF8.self)
        }
    }

    func makeHeaders() throws -> [String: String] {
        if mode == .none { return [:] }
        guard let data = extraHeaders.data(using: .utf8), data.count <= 100_000,
              let extra = try? JSONDecoder().decode([String: String].self, from: data) else {
            throw PluginError.message("Header bổ sung phải là đối tượng JSON có giá trị chuỗi, ví dụ {\"X-Tenant-ID\":\"ten-cua-ban\"}.")
        }
        var headers = extra
        let managedName: String?
        let value: String?
        switch mode {
        case .none, .custom, .oauth:
            managedName = nil; value = nil
        case .bearer:
            var token = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.lowercased().hasPrefix("bearer ") { token = String(token.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard !token.isEmpty else { throw PluginError.message("Nhập Bearer token do server MCP cung cấp.") }
            managedName = "Authorization"; value = "Bearer " + token
        case .apiKey:
            let name = headerName.trimmingCharacters(in: .whitespacesAndNewlines)
            let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !token.isEmpty else { throw PluginError.message("Nhập tên header và API key do server MCP cung cấp.") }
            managedName = name; value = token
        case .basic:
            guard !username.isEmpty, !password.isEmpty else { throw PluginError.message("Nhập tên đăng nhập và mật khẩu của server MCP.") }
            guard !username.contains(":"), !username.utf8.contains(where: { $0 < 32 || $0 == 127 }),
                  !password.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { throw PluginError.message("Thông tin HTTP Basic không hợp lệ; tên đăng nhập không được chứa dấu hai chấm hoặc ký tự điều khiển.") }
            managedName = "Authorization"
            value = "Basic " + Data((username + ":" + password).utf8).base64EncodedString()
        }
        if mode == .oauth, headers.keys.contains(where: { $0.caseInsensitiveCompare("Authorization") == .orderedSame }) {
            throw PluginError.message("OAuth tự tạo header Authorization. Xóa header này khỏi phần bổ sung.")
        }
        if let managedName, let value {
            guard !headers.keys.contains(where: { $0.caseInsensitiveCompare(managedName) == .orderedSame }) else {
                throw PluginError.message("Header \(managedName) đã có trong phần bổ sung. Xóa bản trùng để tránh gửi sai thông tin xác thực.")
            }
            headers[managedName] = value
        }
        try MCPServerConfiguration(url: "https://validation.invalid/mcp", headers: headers).validate()
        return headers
    }

    func applying(to connections: [MCPPluginConnection]) throws -> [MCPPluginConnection] {
        guard connections.count == 1, var connection = connections.first, connection.configuration.url != nil else {
            throw PluginError.message("Nhập xác thực riêng cho một server HTTP. Cấu hình nhiều server hoặc server local cần đặt thông tin trong JSON.")
        }
        let headers = try makeHeaders()
        connection.service = service
        if service?.isWordPress == true { connection.allowedAbilities = [] }
        connection.configuration.headers = headers.isEmpty ? nil : headers
        if mode == .oauth {
            guard let port = UInt16(oauthCallbackPort), port >= 1024 else { throw PluginError.message("Cổng nhận kết quả OAuth phải từ 1024 đến 65535.") }
            connection.oauth = MCPOAuthSettings(clientID: oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines),
                scopes: oauthScopes.trimmingCharacters(in: .whitespacesAndNewlines), callbackPort: port)
            let redirect = oauthPublicRedirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
            connection.oauth?.publicRedirectURI = redirect.isEmpty ? nil : redirect
            try connection.oauth?.validate()
        } else { connection.oauth = nil }
        try connection.configuration.validate()
        return [connection]
    }
}
