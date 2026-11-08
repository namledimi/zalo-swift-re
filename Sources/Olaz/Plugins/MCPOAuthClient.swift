import Foundation
import CryptoKit
import Security

@MainActor
final class MCPOAuthClient {
    struct Discovery: Equatable {
        var resource: String
        var issuer: String
        var authorizationEndpoint: URL
        var tokenEndpoint: URL
        var registrationEndpoint: URL?
        var scopes: String
        var authMethods: [String]
    }
    private let session: URLSession
    private let policy = MCPOAuthRedirectPolicy()

    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 35
        self.session = session ?? URLSession(configuration: config, delegate: policy, delegateQueue: nil)
    }

    func discover(_ server: URL) async throws -> Discovery {
        try Self.validateEndpoint(server)
        let probe = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "Olaz", "version": "1.0"]]])
        let (response, body) = try await request(server, method: "POST", body: probe, contentType: "application/json")
        if response.statusCode == 403 { throw MCPClient.httpError(status: response.statusCode, body: body) }
        let challenge = response.value(forHTTPHeaderField: "WWW-Authenticate") ?? ""
        var locations: [URL]
        if let metadata = Self.challengeValue("resource_metadata", in: challenge), let url = URL(string: metadata) {
            locations = [url]
        } else { locations = Self.wellKnownURLs(server, name: "oauth-protected-resource", includeOIDC: false) }
        var resourceMetadata: [String: Any]?
        for url in locations {
            let (http, data) = try await request(url)
            if http.statusCode == 404 || http.statusCode == 405 { continue }
            guard (200..<300).contains(http.statusCode) else { throw MCPClient.httpError(status: http.statusCode, body: data) }
            resourceMetadata = try MCPClient.object(data); break
        }
        guard let metadata = resourceMetadata, let resource = metadata["resource"] as? String,
              let resourceURL = URL(string: resource), Self.canonical(resourceURL) == Self.canonical(server),
              let issuers = metadata["authorization_servers"] as? [String], let issuer = issuers.first,
              let issuerURL = URL(string: issuer) else {
            throw PluginError.message("Server chưa công bố metadata OAuth hợp lệ cho địa chỉ MCP này. Kiểm tra hướng dẫn xác thực của server.")
        }
        try Self.validateEndpoint(issuerURL)
        var authorizationMetadata: [String: Any]?
        for url in Self.wellKnownURLs(issuerURL, name: "oauth-authorization-server", includeOIDC: true) {
            let (http, data) = try await request(url)
            if http.statusCode == 404 || http.statusCode == 405 { continue }
            guard (200..<300).contains(http.statusCode) else { throw MCPClient.httpError(status: http.statusCode, body: data) }
            authorizationMetadata = try MCPClient.object(data); break
        }
        guard let auth = authorizationMetadata, auth["issuer"] as? String == issuer,
              let authorization = (auth["authorization_endpoint"] as? String).flatMap(URL.init(string:)),
              let token = (auth["token_endpoint"] as? String).flatMap(URL.init(string:)) else {
            throw PluginError.message("Metadata máy chủ OAuth không hợp lệ hoặc issuer không khớp.")
        }
        guard (auth["code_challenge_methods_supported"] as? [String])?.contains("S256") == true else {
            throw PluginError.message("Server OAuth chưa công bố hỗ trợ PKCE S256; Olaz không thể đăng nhập an toàn.")
        }
        try Self.validateEndpoint(authorization); try Self.validateEndpoint(token)
        let registration = (auth["registration_endpoint"] as? String).flatMap(URL.init(string:))
        if let registration { try Self.validateEndpoint(registration) }
        return Discovery(resource: resource, issuer: issuer, authorizationEndpoint: authorization,
            tokenEndpoint: token, registrationEndpoint: registration,
            scopes: Self.challengeValue("scope", in: challenge) ?? (metadata["scopes_supported"] as? [String])?.joined(separator: " ") ?? "",
            authMethods: auth["token_endpoint_auth_methods_supported"] as? [String] ?? ["client_secret_basic"])
    }

    func login(server: URL, settings: MCPOAuthSettings, previous: MCPOAuthCredentials?,
               browser: any MCPOAuthBrowser) async throws -> MCPOAuthCredentials {
        try settings.validate()
        let discovery = try await discover(server)
        let redirectURI = try await browser.start(port: settings.callbackPort, publicRedirectURI: settings.publicRedirectURI.flatMap(URL.init(string:)))
        defer { browser.close() }
        var credentials = MCPOAuthCredentials()
        credentials.issuer = discovery.issuer; credentials.resource = discovery.resource
        credentials.tokenEndpoint = discovery.tokenEndpoint.absoluteString
        if !settings.clientID.isEmpty {
            credentials.clientID = settings.clientID
            credentials.clientSecret = previous?.clientSecret
            credentials.tokenAuthMethod = credentials.clientSecret?.isEmpty == false
                ? (discovery.authMethods.first(where: { ["client_secret_basic", "client_secret_post"].contains($0) }) ?? "none") : "none"
        } else if let previous, !previous.clientID.isEmpty, previous.issuer == discovery.issuer, previous.resource == discovery.resource {
            credentials.clientID = previous.clientID; credentials.clientSecret = previous.clientSecret
            credentials.tokenAuthMethod = previous.tokenAuthMethod
        } else if let registration = discovery.registrationEndpoint {
            let document: [String: Any] = ["client_name": "Olaz", "redirect_uris": [redirectURI.absoluteString],
                "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
                "token_endpoint_auth_method": "none", "application_type": settings.publicRedirectURI == nil ? "native" : "web"]
            let result = try await json(registration, stage: .registration, method: "POST", body: JSONSerialization.data(withJSONObject: document), contentType: "application/json")
            guard let clientID = result["client_id"] as? String, !clientID.isEmpty else {
                throw PluginError.message("Server không cấp OAuth Client ID. Nhập Client ID trong phần nâng cao theo hướng dẫn của server.")
            }
            credentials.clientID = clientID; credentials.clientSecret = result["client_secret"] as? String
            credentials.tokenAuthMethod = result["token_endpoint_auth_method"] as? String ?? "none"
        } else {
            throw PluginError.message("Server không hỗ trợ đăng ký OAuth tự động. Mở Sửa… → OAuth → Cấu hình nâng cao để nhập Client ID đã đăng ký với redirect URI hiển thị.")
        }
        guard discovery.authMethods.contains(credentials.tokenAuthMethod),
              ["none", "client_secret_basic", "client_secret_post"].contains(credentials.tokenAuthMethod) else {
            throw PluginError.message("Server yêu cầu kiểu xác thực OAuth client chưa được hỗ trợ.")
        }
        let verifier = try Self.random()
        let state = try Self.random()
        let scopes = settings.scopes.isEmpty ? discovery.scopes : settings.scopes
        let url = try Self.authorizationURL(discovery: discovery, clientID: credentials.clientID,
            redirectURI: redirectURI, scopes: scopes, verifier: verifier, state: state)
        let callback = try await browser.authorize(url, state: state)
        let code = try Self.authorizationCode(callback: callback, redirectURI: redirectURI, state: state, issuer: discovery.issuer)
        return try await token(credentials, stage: .codeExchange, parameters: ["grant_type": "authorization_code", "code": code,
            "redirect_uri": redirectURI.absoluteString, "code_verifier": verifier, "resource": discovery.resource])
    }

    func refresh(_ credentials: MCPOAuthCredentials) async throws -> MCPOAuthCredentials {
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty, let resource = credentials.resource else {
            throw PluginError.message("Phiên OAuth đã hết hạn. Chọn Đăng nhập OAuth để đăng nhập lại.")
        }
        return try await token(credentials, stage: .refresh, parameters: ["grant_type": "refresh_token", "refresh_token": refreshToken, "resource": resource])
    }

    private func token(_ credentials: MCPOAuthCredentials, stage: MCPOAuthStage, parameters: [String: String]) async throws -> MCPOAuthCredentials {
        guard let endpoint = credentials.tokenEndpoint.flatMap(URL.init(string:)) else { throw PluginError.message("Thiếu token endpoint OAuth. Hãy đăng nhập lại.") }
        var params = parameters
        params["client_id"] = credentials.clientID
        var authorization: String?
        if credentials.tokenAuthMethod != "none" {
            guard let secret = credentials.clientSecret, !secret.isEmpty else { throw PluginError.message("Thiếu OAuth Client Secret. Nhập trong cấu hình nâng cao.") }
            if credentials.tokenAuthMethod == "client_secret_post" { params["client_secret"] = secret }
            else if credentials.tokenAuthMethod == "client_secret_basic" {
                authorization = "Basic " + Data((Self.formEncode(credentials.clientID) + ":" + Self.formEncode(secret)).utf8).base64EncodedString()
            } else { throw PluginError.message("Kiểu xác thực OAuth client chưa được hỗ trợ.") }
        }
        let result = try await json(endpoint, stage: stage, method: "POST", body: Self.formData(params), contentType: "application/x-www-form-urlencoded", authorization: authorization)
        guard let accessToken = result["access_token"] as? String, !accessToken.isEmpty,
              (result["token_type"] as? String)?.lowercased() == "bearer" else {
            throw PluginError.message("Server không trả về Bearer access token hợp lệ.")
        }
        try MCPServerConfiguration(url: "https://validation.invalid/mcp", headers: ["Authorization": "Bearer " + accessToken]).validate()
        var updated = credentials
        updated.accessToken = accessToken
        if let refresh = result["refresh_token"] as? String, !refresh.isEmpty { updated.refreshToken = refresh }
        if let seconds = result["expires_in"] as? NSNumber, seconds.doubleValue > 0, seconds.doubleValue.isFinite {
            updated.expiresAt = Date.now.addingTimeInterval(seconds.doubleValue)
        } else { updated.expiresAt = nil }
        return updated
    }

    static func authorizationURL(discovery: Discovery, clientID: String, redirectURI: URL, scopes: String, verifier: String, state: String) throws -> URL {
        var url = URLComponents(url: discovery.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        let parameters = ["response_type": "code", "client_id": clientID, "redirect_uri": redirectURI.absoluteString,
            "state": state, "code_challenge": challenge(verifier), "code_challenge_method": "S256", "resource": discovery.resource]
        let reserved = Set(parameters.keys).union(["scope"])
        url.queryItems = (url.queryItems ?? []).filter { !reserved.contains($0.name) }
            + parameters.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        if !scopes.isEmpty { url.queryItems?.append(URLQueryItem(name: "scope", value: scopes)) }
        guard let result = url.url else { throw PluginError.message("Không tạo được địa chỉ đăng nhập OAuth.") }
        return result
    }

    static func authorizationCode(callback: URL, redirectURI: URL, state: String, issuer: String) throws -> String {
        guard callback.scheme == redirectURI.scheme, callback.host == redirectURI.host,
              callback.port == redirectURI.port, callback.path == redirectURI.path,
              callback.user == nil, callback.password == nil,
              callback.fragment == nil, let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
            throw PluginError.message("Địa chỉ trả về OAuth không khớp.")
        }
        func single(_ key: String) -> String? { let matches = query.filter { $0.name == key }; return matches.count == 1 ? matches[0].value : nil }
        guard ["code", "state", "iss", "error"].allSatisfy({ key in query.filter { $0.name == key }.count <= 1 }) else {
            throw PluginError.message("Kết quả OAuth chứa tham số trùng lặp.")
        }
        guard single("state") == state else { throw PluginError.message("Phiên đăng nhập OAuth không khớp (state). Hãy thử đăng nhập lại.") }
        if let returnedIssuer = single("iss"), returnedIssuer != issuer { throw PluginError.message("Issuer trả về OAuth không khớp.") }
        guard single("error") == nil, let code = single("code"), !code.isEmpty else { throw PluginError.message("Đăng nhập OAuth bị hủy hoặc chưa được cấp quyền.") }
        return code
    }

    static func challenge(_ verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    private static func random() throws -> String {
        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw PluginError.message("Không tạo được mã bảo vệ phiên OAuth.") }
        return base64URL(data)
    }
    private static func base64URL(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func formEncode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))! }
    static func formData(_ values: [String: String]) -> Data { Data(values.sorted { $0.key < $1.key }.map { formEncode($0.key) + "=" + formEncode($0.value) }.joined(separator: "&").utf8) }
    static func challengeValue(_ name: String, in header: String) -> String? {
        let pattern = "(?i)(?:^|[,\\s])" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*\"([^\"]*)\""
        guard let range = header.range(of: pattern, options: .regularExpression) else { return nil }
        let match = String(header[range]); guard let quote = match.firstIndex(of: "\"") else { return nil }
        return String(match[match.index(after: quote)..<match.index(before: match.endIndex)])
    }
    static func wellKnownURLs(_ url: URL, name: String, includeOIDC: Bool) -> [URL] {
        var origin = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let path = origin.percentEncodedPath == "/" ? "" : origin.percentEncodedPath
        origin.path = ""; origin.query = nil; origin.fragment = nil
        let base = origin.url!.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var paths = ["/.well-known/" + name + path]
        if includeOIDC { paths += ["/.well-known/openid-configuration" + path, path + "/.well-known/openid-configuration"] }
        else if !path.isEmpty { paths += ["/.well-known/" + name] }
        var seen: Set<String> = []
        return paths.compactMap { URL(string: base + $0) }.filter { seen.insert($0.absoluteString).inserted }
    }
    static func canonical(_ url: URL) -> String {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        c.scheme = c.scheme?.lowercased(); c.host = c.host?.lowercased()
        if c.path == "/" { c.path = "" }
        return c.string ?? ""
    }
    private static func validateEndpoint(_ url: URL) throws { try MCPServerConfiguration(url: url.absoluteString).validate() }

    private func json(_ url: URL, stage: MCPOAuthStage, method: String = "GET", body: Data? = nil, contentType: String? = nil, authorization: String? = nil) async throws -> [String: Any] {
        let (http, data) = try await request(url, method: method, body: body, contentType: contentType, authorization: authorization)
        guard (200..<300).contains(http.statusCode) else {
            throw MCPOAuthRequestError(stage: stage, status: http.statusCode, body: data)
        }
        return try MCPClient.object(data)
    }
    private func request(_ url: URL, method: String = "GET", body: Data? = nil, contentType: String? = nil, authorization: String? = nil) async throws -> (HTTPURLResponse, Data) {
        try Self.validateEndpoint(url)
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw PluginError.message("OAuth không trả về HTTP hợp lệ.") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_000_000 else { throw PluginError.message("Metadata OAuth vượt quá 1 MB.") }
            data.append(byte)
        }
        return (http, data)
    }
}

private final class MCPOAuthRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
