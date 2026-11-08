import AppKit
import Network

@MainActor protocol MCPOAuthBrowser {
    func start(port: UInt16, publicRedirectURI: URL?) async throws -> URL
    func authorize(_ url: URL, state: String) async throws -> URL
    func close()
}

extension MCPOAuthBrowser {
    func start(port: UInt16) async throws -> URL { try await start(port: port, publicRedirectURI: nil) }
}

/// A short-lived listener bound only to IPv4 loopback, opened before launching the system browser.
@MainActor final class MCPOAuthBrowserSession: MCPOAuthBrowser {
    private var listener: NWListener?
    private var ready: CheckedContinuation<URL, any Error>?
    private var callback: CheckedContinuation<URL, any Error>?
    private var redirectURI: URL?
    private(set) var localCallbackURI: URL?
    private var expectedState = ""
    private var timeout: Task<Void, Never>?
    private var connections: [UUID: NWConnection] = [:]
    private let openURL: (URL) -> Bool

    init(openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) { self.openURL = openURL }

    func start(port: UInt16, publicRedirectURI: URL?) async throws -> URL {
        if let publicRedirectURI { try MCPOAuthSettings.validatePublicRedirect(publicRedirectURI.absoluteString) }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = self.listener?.port else { return }
                    var local = URLComponents()
                    local.scheme = "http"; local.host = "127.0.0.1"; local.port = Int(port.rawValue)
                    local.percentEncodedPath = publicRedirectURI.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath } ?? "/callback"
                    if local.percentEncodedPath.isEmpty { local.percentEncodedPath = "/" }
                    self.localCallbackURI = local.url
                    let url = publicRedirectURI ?? local.url!
                    self.redirectURI = url
                    self.ready?.resume(returning: url); self.ready = nil
                case .failed:
                    self.finish(error: PluginError.message("Không mở được cổng OAuth trên máy. Đổi cổng trong cấu hình nâng cao rồi thử lại."))
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.receive(connection) } }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(10)); self?.finish(error: PluginError.message("Không khởi tạo được cổng OAuth.")) } catch {}
                }
                listener.start(queue: .main)
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(error: CancellationError()) } }
    }

    func authorize(_ url: URL, state: String) async throws -> URL {
        expectedState = state
        timeout?.cancel()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                callback = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(180)); self?.finish(error: PluginError.message("Đăng nhập OAuth quá thời gian. Chọn đăng nhập lại khi bạn sẵn sàng.")) } catch {}
                }
                if !openURL(url) { finish(error: PluginError.message("Không mở được trình duyệt để đăng nhập OAuth.")) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(error: CancellationError()) } }
    }

    func close() { finish(error: CancellationError()) }

    private func finish(error: any Error) {
        timeout?.cancel(); timeout = nil
        ready?.resume(throwing: error); ready = nil
        callback?.resume(throwing: error); callback = nil
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections = [:]
    }

    private func receive(_ connection: NWConnection) {
        guard connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        read(connection, id: id, buffered: Data())
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.connections.removeValue(forKey: id)?.cancel()
        }
    }

    private func read(_ connection: NWConnection, id: UUID, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var buffer = buffered
                if let data { buffer.append(data) }
                guard buffer.count <= 16_384, error == nil else { self.connections.removeValue(forKey: id)?.cancel(); return }
                if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.handle(buffer, connection: connection, id: id)
                } else if !complete { self.read(connection, id: id, buffered: buffer) }
                else { self.connections.removeValue(forKey: id)?.cancel() }
            }
        }
    }

    private func handle(_ data: Data, connection: NWConnection, id: UUID) {
        let line = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/"),
              let redirectURI, var components = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false),
              let incoming = URLComponents(string: String(parts[1])),
              incoming.percentEncodedPath == (components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath),
              incoming.scheme == nil, incoming.host == nil else {
            respond(connection, id: id, status: "404 Not Found", text: "Không tìm thấy trang."); return
        }
        let states = incoming.queryItems?.filter { $0.name == "state" } ?? []
        guard !expectedState.isEmpty, states.count == 1, states[0].value == expectedState, callback != nil else {
            respond(connection, id: id, status: "400 Bad Request", text: "Phiên đăng nhập không khớp. Quay lại Olaz để thử lại."); return
        }
        components.percentEncodedQuery = incoming.percentEncodedQuery
        guard let callbackURL = components.url else { return }
        respond(connection, id: id, status: "200 OK", text: "Đã nhận kết quả đăng nhập. Bạn có thể quay lại Olaz.")
        callback?.resume(returning: callbackURL); callback = nil
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        // Keep this response alive until it has been sent; close() may be called immediately by the OAuth flow.
        connections.removeValue(forKey: id)
    }

    private func respond(_ connection: NWConnection, id: UUID, status: String, text: String) {
        let html = Data(("<!doctype html><html lang=\"vi\"><meta charset=\"utf-8\"><title>Olaz</title><p>" + text + "</p></html>").utf8)
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.count)\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'\r\n\r\n"
        connection.send(content: Data(headers.utf8) + html, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            Task { @MainActor in self?.connections.removeValue(forKey: id) }
        })
    }
}
