import Foundation
import Security

enum MCPOAuthStage: Sendable {
    case registration, codeExchange, refresh
    var title: String {
        switch self {
        case .registration: "Đăng ký ứng dụng OAuth"
        case .codeExchange: "Đổi mã đăng nhập OAuth"
        case .refresh: "Làm mới phiên OAuth"
        }
    }
}

/// Only recognized error codes and local guidance are displayed; server error bodies can contain secrets.
struct MCPOAuthRequestError: LocalizedError, Sendable {
    var stage: MCPOAuthStage
    var status: Int
    var code: String?
    var registrationUnavailable: Bool

    init(stage: MCPOAuthStage, status: Int, body: Data) {
        self.stage = stage; self.status = status
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let knownCodes: Set<String> = ["invalid_client_metadata", "invalid_redirect_uri", "invalid_client", "unauthorized_client",
            "invalid_scope", "invalid_grant", "access_denied", "invalid_request", "unsupported_grant_type", "server_error", "temporarily_unavailable"]
        let rawCode = object?["error"] as? String
        code = rawCode.flatMap { knownCodes.contains($0) ? $0 : nil }
        registrationUnavailable = stage == .registration && code == "invalid_client_metadata"
            && (object?["error_description"] as? String)?.lowercased().contains("dynamic registration is not available") == true
    }

    var errorDescription: String? {
        let detail = "HTTP \(status)" + (code.map { ", \($0)" } ?? "")
        if registrationUnavailable {
            return "Server không cho Olaz tự đăng ký ứng dụng OAuth (\(detail)). Trang đăng nhập chưa được mở. Chọn Sửa… → Cấu hình OAuth nâng cao, nhập Client ID được server chấp nhận và đăng ký đúng Redirect URI hiển thị."
        }
        switch code {
        case "invalid_client_metadata" where stage == .registration:
            return "Server từ chối thông tin đăng ký ứng dụng OAuth (\(detail)). Kiểm tra Client ID và Redirect URI trong Cấu hình OAuth nâng cao theo hướng dẫn của server."
        case "invalid_redirect_uri":
            return "Server từ chối Redirect URI OAuth (\(detail)). Đăng ký đúng địa chỉ hiển thị trong Cấu hình OAuth nâng cao với Client ID của bạn."
        case "invalid_client", "unauthorized_client":
            return "Ứng dụng OAuth chưa được server chấp nhận (\(detail)). Kiểm tra Client ID, Client Secret nếu cần và quyền của ứng dụng trên server."
        case "invalid_scope":
            return "Server từ chối scope OAuth (\(detail)). Kiểm tra quyền đã cấp cho ứng dụng và scope trong Cấu hình OAuth nâng cao."
        case "invalid_grant":
            return "Mã đăng nhập hoặc phiên OAuth đã hết hạn hay bị thu hồi (\(detail)). Chọn Đăng nhập OAuth để đăng nhập lại."
        case "access_denied":
            return "Server từ chối cấp quyền OAuth (\(detail)). Kiểm tra quyền truy cập của tài khoản và ứng dụng."
        default:
            return "\(stage.title) thất bại (\(detail)). Kiểm tra cấu hình client và quyền trên server."
        }
    }
}

struct MCPOAuthSettings: Codable, Equatable, Sendable {
    var clientID = ""
    var scopes = ""
    var callbackPort: UInt16 = 8765
    var publicRedirectURI: String?
    var redirectURI: URL {
        publicRedirectURI.flatMap(URL.init(string:)) ?? URL(string: "http://127.0.0.1:\(callbackPort)/callback")!
    }

    func validate() throws {
        guard callbackPort >= 1024 else { throw PluginError.message("Cổng nhận kết quả OAuth phải từ 1024 đến 65535.") }
        if let publicRedirectURI { try Self.validatePublicRedirect(publicRedirectURI) }
    }

    static func validatePublicRedirect(_ text: String) throws {
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }),
              let components = URLComponents(string: text), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil, components.url != nil else {
            throw PluginError.message("Callback công khai phải là URL HTTPS đầy đủ, không có tài khoản, query hay fragment; ví dụ https://ten-mien-cua-ban/callback.")
        }
    }
}

/// Stored separately from Plugin settings; refresh tokens and client secrets stay out of provider configuration.
struct MCPOAuthCredentials: Codable, Equatable, Sendable {
    var clientID = ""
    var clientSecret: String?
    var tokenEndpoint: String?
    var tokenAuthMethod = "none"
    var issuer: String?
    var resource: String?
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Date?
}

@MainActor protocol MCPOAuthCredentialStore {
    func read(_ id: UUID) throws -> MCPOAuthCredentials?
    func write(_ credentials: MCPOAuthCredentials, for id: UUID) throws
    func remove(_ id: UUID) throws
    func allowRetry(_ id: UUID)
}

extension MCPOAuthCredentialStore {
    func allowRetry(_ id: UUID) {}
}

/// One cache per running app. Repeated replies reuse credentials already read with the user's permission.
/// Failed reads are held until an explicit Plugin action, so denying the system dialog does not cause a loop.
@MainActor final class MCPOAuthSessionStore: MCPOAuthCredentialStore {
    private enum Entry {
        case loaded(MCPOAuthCredentials?)
        case failed(any Error)
    }
    private let backing: any MCPOAuthCredentialStore
    private var entries: [UUID: Entry] = [:]

    init(backing: any MCPOAuthCredentialStore) { self.backing = backing }

    func read(_ id: UUID) throws -> MCPOAuthCredentials? {
        if let entry = entries[id] {
            switch entry {
            case .loaded(let credentials): return credentials
            case .failed(let error): throw error
            }
        }
        do {
            let credentials = try backing.read(id)
            entries[id] = .loaded(credentials)
            return credentials
        } catch {
            entries[id] = .failed(error)
            throw error
        }
    }

    func write(_ credentials: MCPOAuthCredentials, for id: UUID) throws {
        do {
            try backing.write(credentials, for: id)
            entries[id] = .loaded(credentials)
        } catch {
            entries[id] = .failed(error)
            throw error
        }
    }

    func remove(_ id: UUID) throws {
        try backing.remove(id)
        entries[id] = .loaded(nil)
    }

    func allowRetry(_ id: UUID) {
        if case .failed? = entries[id] { entries.removeValue(forKey: id) }
        backing.allowRetry(id)
    }
}

struct MCPOAuthKeychainStore: MCPOAuthCredentialStore {
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.olaz.mcp.oauth",
         kSecAttrAccount as String: id.uuidString]
    }
    func read(_ id: UUID) throws -> MCPOAuthCredentials? {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        return try JSONDecoder().decode(MCPOAuthCredentials.self, from: data)
    }
    func write(_ credentials: MCPOAuthCredentials, for id: UUID) throws {
        let data = try JSONEncoder().encode(credentials)
        let attributes = [kSecValueData as String: data] as [String: Any]
        var status = SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(id)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status) }
    }
    func remove(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
    private func failure(_ status: OSStatus) -> PluginError {
        .message("Không truy cập được Keychain cho OAuth (\(status)). Kiểm tra quyền Keychain của Olaz.")
    }
}
