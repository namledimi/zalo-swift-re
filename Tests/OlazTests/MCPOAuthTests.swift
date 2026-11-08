import Foundation
import Testing
@testable import Olaz

@MainActor @Suite(.serialized) struct MCPOAuthTests {
    private let server = URL(string: "https://mcp.fixture.invalid/tenant/mcp")!
    private let issuer = "https://identity.fixture.invalid/tenant"

    private func client(state: OAuthFixtureState = OAuthFixtureState(), pkce: Bool = true, expectedIssuer: String? = nil,
                        resource: String? = nil, registration: Bool = true, challenge: Bool = true, oidcOnly: Bool = false) -> MCPOAuthClient {
        let server = server.absoluteString, issuer = issuer
        OAuthFixtureProtocol.handler = { request in
            let path = request.url!.path
            func result(_ object: [String: Any], status: Int = 200, headers: [String: String] = [:]) throws -> (Int, [String: String], Data) {
                (status, ["Content-Type": "application/json"].merging(headers) { _, new in new }, try JSONSerialization.data(withJSONObject: object))
            }
            if path == "/tenant/mcp" {
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                return try result([:], status: 401, headers: challenge ? ["WWW-Authenticate": "Bearer resource_metadata=\"https://mcp.fixture.invalid/metadata\", scope=\"data:read\""] : [:])
            }
            if path == "/metadata" || path == "/.well-known/oauth-protected-resource/tenant/mcp" {
                return try result(["resource": resource ?? server, "authorization_servers": [issuer], "scopes_supported": ["fallback:read"]])
            }
            if path == "/.well-known/oauth-authorization-server/tenant" || path == "/.well-known/openid-configuration/tenant" {
                if oidcOnly && path.contains("oauth-authorization-server") { return try result([:], status: 404) }
                var metadata: [String: Any] = ["issuer": expectedIssuer ?? issuer,
                    "authorization_endpoint": "https://identity.fixture.invalid/authorize?provider=fixture",
                    "token_endpoint": "https://identity.fixture.invalid/token",
                    "token_endpoint_auth_methods_supported": ["none", "client_secret_basic", "client_secret_post"]]
                if pkce { metadata["code_challenge_methods_supported"] = ["S256"] }
                if registration { metadata["registration_endpoint"] = "https://identity.fixture.invalid/register" }
                return try result(metadata)
            }
            if path == "/register" {
                state.registrations += 1
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                #expect(body["client_name"] as? String == "Olaz")
                #expect(body["redirect_uris"] as? [String] == [state.expectedRedirectURI])
                #expect(body["application_type"] as? String == (state.expectedRedirectURI.hasPrefix("https:") ? "web" : "native"))
                #expect(body["token_endpoint_auth_method"] as? String == "none")
                if state.rejectRegistration {
                    return try result(["error": "invalid_client_metadata", "error_description": "Dynamic registration is not available for this client."], status: 400)
                }
                return try result(["client_id": "fixture-dynamic-client", "token_endpoint_auth_method": "none"])
            }
            if path == "/token" {
                let raw = String(decoding: request.httpBody!, as: UTF8.self)
                let parameters = URLComponents(string: "https://fixture.invalid/?" + raw)!.queryItems!
                let form = Dictionary(uniqueKeysWithValues: parameters.map { ($0.name, $0.value!) })
                state.tokenRequests.append(form)
                state.tokenAuthorization = request.value(forHTTPHeaderField: "Authorization")
                #expect(form["resource"] == server)
                #expect(request.url?.query == nil)
                if state.rejectToken { return try result(["error": "invalid_grant", "error_description": "PRIVATE_SERVER_DETAIL"], status: 400) }
                if form["grant_type"] == "authorization_code" {
                    #expect(form["code"] == "fixture-code")
                    #expect(form["code_verifier"]?.count == 43)
                    #expect(form["redirect_uri"] == state.expectedRedirectURI)
                    return try result(["access_token": "fixture-access", "refresh_token": "fixture-refresh", "token_type": "Bearer", "expires_in": 3600])
                }
                #expect(form["refresh_token"] == "fixture-refresh")
                return try result(["access_token": "fixture-access-rotated", "refresh_token": "fixture-refresh-rotated", "token_type": "Bearer", "expires_in": 3600])
            }
            Issue.record("Unexpected OAuth fixture request")
            return try result([:], status: 404)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OAuthFixtureProtocol.self]
        return MCPOAuthClient(session: URLSession(configuration: config))
    }

    @Test func pkceAndDiscoveryPathsMatchStandards() {
        #expect(MCPOAuthClient.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(MCPOAuthClient.wellKnownURLs(server, name: "oauth-protected-resource", includeOIDC: false).map(\.absoluteString) == [
            "https://mcp.fixture.invalid/.well-known/oauth-protected-resource/tenant/mcp",
            "https://mcp.fixture.invalid/.well-known/oauth-protected-resource"])
        #expect(MCPOAuthClient.wellKnownURLs(URL(string: issuer)!, name: "oauth-authorization-server", includeOIDC: true).map(\.path) == [
            "/.well-known/oauth-authorization-server/tenant", "/.well-known/openid-configuration/tenant", "/tenant/.well-known/openid-configuration"])
        #expect(MCPOAuthClient.challengeValue("scope", in: "Bearer resource_metadata=\"https://fixture.invalid/meta\", scope=\"read write\"") == "read write")
    }

    @Test func discoveryUsesChallengeAndFallsBackToOIDCAndWellKnownMetadata() async throws {
        defer { OAuthFixtureProtocol.handler = nil }
        let discovered = try await client().discover(server)
        #expect(discovered.issuer == issuer && discovered.scopes == "data:read")
        #expect(discovered.registrationEndpoint?.path == "/register")
        let fallback = try await client(challenge: false, oidcOnly: true).discover(server)
        #expect(fallback.scopes == "fallback:read")
    }

    @Test func discoveryRejectsMissingPKCEWrongIssuerAndWrongResource() async {
        defer { OAuthFixtureProtocol.handler = nil }
        await #expect(throws: (any Error).self) { try await client(pkce: false).discover(server) }
        await #expect(throws: (any Error).self) { try await client(expectedIssuer: "https://impostor.invalid").discover(server) }
        await #expect(throws: (any Error).self) { try await client(resource: "https://other.invalid/mcp").discover(server) }
    }

    @Test func dynamicOAuthLoginAndRefreshRotateTokensWithoutExposingSecretsToBrowser() async throws {
        defer { OAuthFixtureProtocol.handler = nil }
        let state = OAuthFixtureState(), browser = OAuthFixtureBrowser()
        let client = client(state: state)
        let credentials = try await client.login(server: server, settings: MCPOAuthSettings(), previous: nil, browser: browser)
        #expect(state.registrations == 1)
        #expect(credentials.accessToken == "fixture-access" && credentials.refreshToken == "fixture-refresh")
        #expect(credentials.expiresAt! > Date.now.addingTimeInterval(3500))
        #expect(browser.closed)
        let url = try #require(browser.openedURL)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.first { $0.name == "resource" }?.value == server.absoluteString)
        #expect(query.first { $0.name == "scope" }?.value == "data:read")
        #expect(query.first { $0.name == "code_challenge_method" }?.value == "S256")
        let verifier = try #require(state.tokenRequests.first?["code_verifier"])
        #expect(query.first { $0.name == "code_challenge" }?.value == MCPOAuthClient.challenge(verifier))
        #expect(!url.absoluteString.contains("fixture-access") && !url.absoluteString.contains("fixture-refresh"))
        let refreshed = try await client.refresh(credentials)
        #expect(refreshed.accessToken == "fixture-access-rotated" && refreshed.refreshToken == "fixture-refresh-rotated")
        state.rejectToken = true
        do { _ = try await client.refresh(refreshed); Issue.record("Accepted invalid_grant") }
        catch { #expect(!error.localizedDescription.contains("PRIVATE_SERVER_DETAIL")) }
    }

    @Test func preRegisteredClientSkipsRegistrationAndAuthenticatesTokenRequest() async throws {
        defer { OAuthFixtureProtocol.handler = nil }
        let state = OAuthFixtureState(), browser = OAuthFixtureBrowser()
        let settings = MCPOAuthSettings(clientID: "fixture-client", scopes: "custom:read")
        var previous = MCPOAuthCredentials()
        previous.clientSecret = "fixture:secret+value"
        let credentials = try await client(state: state, registration: false).login(server: server, settings: settings, previous: previous, browser: browser)
        #expect(state.registrations == 0)
        #expect(credentials.tokenAuthMethod == "client_secret_basic")
        #expect(state.tokenAuthorization == "Basic " + Data("fixture-client:fixture%3Asecret%2Bvalue".utf8).base64EncodedString())
        #expect(!browser.openedURL!.absoluteString.contains("secret"))
        await #expect(throws: (any Error).self) {
            try await client(registration: false).login(server: server, settings: MCPOAuthSettings(), previous: nil, browser: OAuthFixtureBrowser())
        }
    }

    @Test func registrationDenialExplainsClientSetupBeforeOpeningBrowser() async throws {
        defer { OAuthFixtureProtocol.handler = nil }
        let state = OAuthFixtureState(), browser = OAuthFixtureBrowser()
        state.rejectRegistration = true
        do {
            _ = try await client(state: state).login(server: server, settings: MCPOAuthSettings(), previous: nil, browser: browser)
            Issue.record("Accepted rejected client registration")
        } catch let error as MCPOAuthRequestError {
            #expect(error.stage == .registration && error.status == 400 && error.code == "invalid_client_metadata")
            #expect(error.registrationUnavailable)
            #expect(error.localizedDescription.contains("Client ID") && error.localizedDescription.contains("Redirect URI"))
            #expect(error.localizedDescription.contains("Trang đăng nhập chưa được mở"))
        }
        #expect(browser.openedURL == nil && browser.closed)
        #expect(state.registrations == 1 && state.tokenRequests.isEmpty)
    }

    @Test func httpsCallbackIsUsedForRegistrationAuthorizationAndTokenExchange() async throws {
        defer { OAuthFixtureProtocol.handler = nil }
        let state = OAuthFixtureState(), browser = OAuthFixtureBrowser()
        state.expectedRedirectURI = "https://callback.fixture.invalid/olaz/oauth/callback"
        var settings = MCPOAuthSettings()
        settings.publicRedirectURI = state.expectedRedirectURI
        let credentials = try await client(state: state).login(server: server, settings: settings, previous: nil, browser: browser)
        #expect(credentials.accessToken == "fixture-access")
        #expect(state.registrations == 1)
        let query = URLComponents(url: try #require(browser.openedURL), resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.first { $0.name == "redirect_uri" }?.value == state.expectedRedirectURI)
        #expect(state.tokenRequests.first?["redirect_uri"] == state.expectedRedirectURI)
    }

    @Test func callbackConfigurationValidatesHTTPSAndKeepsOldSettingsCompatible() throws {
        let old = try JSONDecoder().decode(MCPOAuthSettings.self, from: Data(#"{"clientID":"existing","scopes":"read","callbackPort":8765}"#.utf8))
        #expect(old.publicRedirectURI == nil && old.redirectURI.absoluteString == "http://127.0.0.1:8765/callback")
        var fields = MCPAuthenticationFields(); fields.mode = .oauth
        fields.oauthPublicRedirectURI = " https://callback.fixture.invalid/olaz/callback "
        let connection = MCPPluginConnection(name: "Fixture", configuration: MCPServerConfiguration(url: server.absoluteString))
        let configured = try #require(fields.applying(to: [connection]).first?.oauth)
        #expect(configured.redirectURI.absoluteString == "https://callback.fixture.invalid/olaz/callback")
        #expect(try JSONDecoder().decode(MCPOAuthSettings.self, from: JSONEncoder().encode(configured)) == configured)
        for invalid in ["http://callback.fixture.invalid/callback", "https://user:secret@callback.fixture.invalid/callback",
                        "https://callback.fixture.invalid/callback?tenant=one", "https://callback.fixture.invalid/callback#fragment", "https://bad host/callback"] {
            fields.oauthPublicRedirectURI = invalid
            #expect(throws: (any Error).self) { try fields.applying(to: [connection]) }
        }
    }

    @Test func oauthErrorsIdentifyTheStageAndDoNotEchoServerSecrets() {
        let unknown = Data(#"{"error":"PRIVATE_CODE_SECRET","error_description":"PRIVATE_DESCRIPTION_SECRET","access_token":"PRIVATE_ACCESS_SECRET"}"#.utf8)
        for stage in [MCPOAuthStage.registration, .codeExchange, .refresh] {
            let error = MCPOAuthRequestError(stage: stage, status: 400, body: unknown)
            #expect(error.code == nil && !error.localizedDescription.contains("PRIVATE"))
            #expect(error.localizedDescription.contains(stage.title))
        }
        let cases = ["invalid_client": "Client ID", "invalid_redirect_uri": "Redirect URI", "invalid_scope": "scope", "invalid_grant": "đăng nhập lại"]
        for (code, guidance) in cases {
            let body = Data(("{\"error\":\"" + code + "\",\"error_description\":\"PRIVATE_SECRET\"}").utf8)
            let error = MCPOAuthRequestError(stage: .codeExchange, status: 400, body: body)
            #expect(error.localizedDescription.contains(guidance) && !error.localizedDescription.contains("PRIVATE"))
        }
    }

    @Test func callbacksRejectWrongStateDuplicateCodeWrongOriginAndIssuer() throws {
        let redirect = MCPOAuthSettings().redirectURI
        #expect(try MCPOAuthClient.authorizationCode(callback: URL(string: redirect.absoluteString + "?code=ok&state=expected")!, redirectURI: redirect, state: "expected", issuer: issuer) == "ok")
        for input in [redirect.absoluteString + "?code=ok&state=wrong", redirect.absoluteString + "?code=one&code=two&state=expected",
                      "http://other.invalid:8765/callback?code=ok&state=expected", redirect.absoluteString + "?code=ok&state=expected&iss=wrong",
                      redirect.absoluteString + "?error=access_denied&state=expected"] {
            #expect(throws: (any Error).self) { try MCPOAuthClient.authorizationCode(callback: URL(string: input)!, redirectURI: redirect, state: "expected", issuer: issuer) }
        }
    }

    @Test func managerKeepsOAuthSecretsOutOfSettingsAndRefreshesBeforeProvidingTools() async throws {
        defer { OAuthFixtureProtocol.handler = nil }
        let state = OAuthFixtureState(), store = OAuthMemoryStore()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsURL = directory.appendingPathComponent("settings.json")
        var manager = PluginManager(storageURL: settingsURL, oauthStore: store, oauthClient: client(state: state))
        var fields = MCPAuthenticationFields(); fields.mode = .oauth
        try manager.add(name: "OAuth fixture", document: server.absoluteString, authentication: fields)
        let id = try #require(manager.settings.connections.first?.id)
        await manager.authenticate(id, browser: OAuthFixtureBrowser())
        #expect(store.values[id]?.accessToken == "fixture-access")
        manager.allowTool("lookup", connection: id, enabled: true); manager.setEnabled(id, true)
        store.values[id]?.expiresAt = .distantPast
        // A fresh app session must load and refresh the expired persisted token.
        manager = PluginManager(storageURL: settingsURL, oauthStore: store, oauthClient: client(state: state))
        let runtime = try await manager.prepareActiveConnections()
        #expect(runtime.first?.configuration.headers?["Authorization"] == "Bearer fixture-access-rotated")
        #expect(runtime.first?.oauth == nil)
        #expect(store.values[id]?.refreshToken == "fixture-refresh-rotated")
        _ = try await manager.prepareActiveConnections()
        #expect(store.readCount == 1)
        #expect(state.tokenRequests.filter { $0["grant_type"] == "refresh_token" }.count == 1)
        let saved = String(decoding: try Data(contentsOf: settingsURL), as: UTF8.self)
        #expect(!saved.contains("fixture-access") && !saved.contains("fixture-refresh"))
        let runtimeJSON = String(decoding: try JSONEncoder().encode(runtime), as: UTF8.self)
        #expect(!runtimeJSON.contains("fixture-refresh") && !runtimeJSON.contains("clientSecret"))
        try manager.update(id, name: "Renamed", document: server.absoluteString, authentication: fields)
        #expect(store.values[id]?.refreshToken == "fixture-refresh-rotated")
        try manager.update(id, name: "Changed host", document: "https://other.fixture.invalid/mcp", authentication: fields)
        #expect(store.values[id]?.accessToken == nil && store.values[id]?.refreshToken == nil)
        manager.remove(id)
        #expect(store.values[id] == nil)
    }

    @Test func credentialSessionCacheReadsOnceAndTracksUpdatesAndRemoval() throws {
        let backing = OAuthMemoryStore(), id = UUID(), otherID = UUID()
        var original = MCPOAuthCredentials(); original.accessToken = "fixture-original"
        backing.values[id] = original
        let session = MCPOAuthSessionStore(backing: backing)
        #expect(try session.read(id) == original)
        #expect(try session.read(id) == original)
        #expect(backing.readCount == 1)
        #expect(try session.read(otherID) == nil)
        #expect(try session.read(otherID) == nil)
        #expect(backing.readCount == 2)
        var rotated = original; rotated.accessToken = "fixture-rotated"
        try session.write(rotated, for: id)
        #expect(try session.read(id) == rotated && backing.values[id] == rotated)
        #expect(backing.readCount == 2)
        let nextSession = MCPOAuthSessionStore(backing: backing)
        #expect(try nextSession.read(id) == rotated && backing.readCount == 3)
        try session.remove(id)
        #expect(try session.read(id) == nil && backing.values[id] == nil)
        #expect(backing.readCount == 3)
    }

    @Test func deniedKeychainReadDoesNotRepeatUntilExplicitRetry() throws {
        let backing = OAuthMemoryStore(), id = UUID()
        backing.readError = PluginError.message("Fixture: access denied")
        let session = MCPOAuthSessionStore(backing: backing)
        #expect(throws: (any Error).self) { try session.read(id) }
        #expect(throws: (any Error).self) { try session.read(id) }
        #expect(backing.readCount == 1)
        backing.readError = nil
        var credentials = MCPOAuthCredentials(); credentials.accessToken = "fixture-token"
        backing.values[id] = credentials
        // Background work keeps reporting the failure instead of raising another system prompt.
        #expect(throws: (any Error).self) { try session.read(id) }
        #expect(backing.readCount == 1)
        session.allowRetry(id)
        #expect(try session.read(id) == credentials)
        #expect(try session.read(id) == credentials && backing.readCount == 2)
    }

    @Test func failedCredentialWriteDoesNotUseUnpersistedTokensOrRetryAutomatically() throws {
        let backing = OAuthMemoryStore(), id = UUID()
        var original = MCPOAuthCredentials(); original.accessToken = "fixture-original"
        backing.values[id] = original
        let session = MCPOAuthSessionStore(backing: backing)
        _ = try session.read(id)
        backing.writeError = PluginError.message("Fixture: write denied")
        var replacement = original; replacement.accessToken = "fixture-unpersisted"
        #expect(throws: (any Error).self) { try session.write(replacement, for: id) }
        #expect(throws: (any Error).self) { try session.read(id) }
        #expect(backing.values[id] == original && backing.readCount == 1)
        backing.writeError = nil
        session.allowRetry(id)
        #expect(try session.read(id) == original && backing.readCount == 2)
    }

    @Test func realLoopbackListenerRejectsWrongStateAndAcceptsCallback() async throws {
        var redirect: URL!
        var requests: Task<Void, Never>?
        let session = MCPOAuthBrowserSession { _ in
            requests = Task { @MainActor in
                do {
                    let (_, wrong) = try await URLSession.shared.data(from: URL(string: redirect.absoluteString + "?code=no&state=wrong")!)
                    #expect((wrong as? HTTPURLResponse)?.statusCode == 400)
                    let (_, right) = try await URLSession.shared.data(from: URL(string: redirect.absoluteString + "?code=ok&state=expected")!)
                    #expect((right as? HTTPURLResponse)?.statusCode == 200)
                } catch { Issue.record("Loopback callback failed: \(error)") }
            }
            return true
        }
        redirect = try await session.start(port: 0)
        defer { session.close() }
        #expect(redirect.host == "127.0.0.1" && redirect.port != 0)
        let callback = try await session.authorize(URL(string: "https://identity.fixture.invalid/authorize")!, state: "expected")
        #expect(try MCPOAuthClient.authorizationCode(callback: callback, redirectURI: redirect, state: "expected", issuer: issuer) == "ok")
        await requests?.value
    }

    @Test(arguments: ["https://callback.fixture.invalid/olaz/oauth/callback", "https://callback.fixture.invalid", "https://callback.fixture.invalid/oauth%20callback"])
    func httpsForwardedCallbackPreservesPublicOriginAndChecksPathAndState(address: String) async throws {
        let publicURL = URL(string: address)!
        var localURL: URL!
        var requests: Task<Void, Never>?
        let session = MCPOAuthBrowserSession { _ in
            requests = Task { @MainActor in
                do {
                    let origin = "http://127.0.0.1:\(localURL.port!)"
                    let (_, wrongPath) = try await URLSession.shared.data(from: URL(string: origin + "/wrong?state=expected&code=no")!)
                    #expect((wrongPath as? HTTPURLResponse)?.statusCode == 404)
                    let (_, wrongState) = try await URLSession.shared.data(from: URL(string: localURL.absoluteString + "?state=wrong&code=no")!)
                    #expect((wrongState as? HTTPURLResponse)?.statusCode == 400)
                    let (_, response) = try await URLSession.shared.data(from: URL(string: localURL.absoluteString + "?state=expected&code=ok")!)
                    #expect((response as? HTTPURLResponse)?.statusCode == 200)
                    #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control") == "no-store")
                } catch { Issue.record("HTTPS callback forwarding failed: \(error)") }
            }
            return true
        }
        let redirect = try await session.start(port: 0, publicRedirectURI: publicURL)
        defer { session.close() }
        localURL = try #require(session.localCallbackURI)
        #expect(redirect == publicURL && localURL.host == "127.0.0.1")
        #expect(localURL.path == (publicURL.path.isEmpty ? "/" : publicURL.path))
        let callback = try await session.authorize(URL(string: "https://identity.fixture.invalid/authorize")!, state: "expected")
        #expect(callback.host == publicURL.host && callback.scheme == "https")
        #expect(try MCPOAuthClient.authorizationCode(callback: callback, redirectURI: publicURL, state: "expected", issuer: issuer) == "ok")
        await requests?.value
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OLAZ_MCP_DISCOVERY_TESTS"] == "1"))
    func discoversPublicMetaMCPWithoutLoggingIn() async throws {
        let result = try await MCPOAuthClient().discover(URL(string: "https://mcp.facebook.com/ads")!)
        #expect(result.issuer == "https://www.facebook.com/ads")
        #expect(result.registrationEndpoint != nil)
        #expect(result.authMethods.contains("none"))
    }
}

private final class OAuthFixtureState: @unchecked Sendable {
    var registrations = 0
    var tokenRequests: [[String: String]] = []
    var tokenAuthorization: String?
    var rejectToken = false
    var rejectRegistration = false
    var expectedRedirectURI = "http://127.0.0.1:8765/callback"
}

@MainActor private final class OAuthFixtureBrowser: MCPOAuthBrowser {
    var openedURL: URL?
    var closed = false
    private var redirectURI: URL!
    func start(port: UInt16, publicRedirectURI: URL?) async throws -> URL {
        redirectURI = publicRedirectURI ?? URL(string: "http://127.0.0.1:\(port)/callback")!
        return redirectURI
    }
    func authorize(_ url: URL, state: String) async throws -> URL {
        openedURL = url
        var callback = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false)!
        callback.queryItems = [URLQueryItem(name: "code", value: "fixture-code"), URLQueryItem(name: "state", value: state)]
        return callback.url!
    }
    func close() { closed = true }
}

@MainActor private final class OAuthMemoryStore: MCPOAuthCredentialStore {
    var values: [UUID: MCPOAuthCredentials] = [:]
    var readCount = 0
    var readError: (any Error)?
    var writeError: (any Error)?
    func read(_ id: UUID) throws -> MCPOAuthCredentials? {
        readCount += 1
        if let readError { throw readError }
        return values[id]
    }
    func write(_ credentials: MCPOAuthCredentials, for id: UUID) throws {
        if let writeError { throw writeError }
        values[id] = credentials
    }
    func remove(_ id: UUID) throws { values.removeValue(forKey: id) }
}

private final class OAuthFixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var prepared = request
            if prepared.httpBody == nil, let stream = prepared.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    data.append(contentsOf: bytes.prefix(count))
                }
                prepared.httpBody = data
            }
            let (status, headers, data) = try Self.handler!(prepared)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
