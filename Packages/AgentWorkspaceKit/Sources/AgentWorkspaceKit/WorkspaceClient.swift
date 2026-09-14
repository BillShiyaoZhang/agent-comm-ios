import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A single-server session. No shared cookie jar and no cross-origin credential redirects.
public actor WorkspaceClient {
    public nonisolated let baseURL: URL
    private let session: URLSession
    private let secureStore: SecureStore?
    private var cookies: [HTTPCookie] = []
    private var restored = false
    private var generation = 0
    private let pollingInterval: UInt64
    private let maximumPolls: Int
    private let executionTimeout: TimeInterval

    public init(server: String, configuration: URLSessionConfiguration = .ephemeral, persistSession: Bool = true,
                pollingInterval: UInt64 = 2_000_000_000, maximumPolls: Int = 65, executionTimeout: TimeInterval = 150) throws {
        let url = try Self.validateServer(server)
        self.baseURL = url
        self.secureStore = persistSession ? SecureStore(namespace: "AgentWorkspaceKit.session.\(url.absoluteString)") : nil
        self.pollingInterval = pollingInterval
        self.maximumPolls = max(0, maximumPolls)
        self.executionTimeout = max(0.01, executionTimeout)
        let config = configuration.copy() as! URLSessionConfiguration
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
    }

    public nonisolated static func validateServer(_ input: String) throws -> URL {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard var parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let rawHost = parts.host?.lowercased(), !rawHost.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", parts.port.map({ (1...65535).contains($0) }) ?? true else {
            throw WorkspaceClientError.invalidURL
        }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if scheme == "http" && !isLocalHost(host) { throw WorkspaceClientError.invalidURL }
        parts.scheme = scheme; parts.host = rawHost; parts.path = ""
        if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) { parts.port = nil }
        guard let url = parts.url else { throw WorkspaceClientError.invalidURL }
        return url
    }

    private nonisolated static func isLocalHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host == "::1" { return true }
        if host.contains(":") {
            // IPv6 unique-local and link-local literals only; Foundation validates the literal URL.
            return host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe8") || host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb")
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && ($0.count == 1 || !$0.hasPrefix("0")) }),
              octets.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) else { return false }
        let numbers = octets.compactMap { Int($0) }
        return numbers[0] == 127 || numbers[0] == 10 || numbers[0] == 192 && numbers[1] == 168 || numbers[0] == 172 && (16...31).contains(numbers[1]) || numbers[0] == 169 && numbers[1] == 254
    }

    /// A connectivity probe checks the actual NextAuth contract without altering the signed-in session.
    public static func testConnection(server: String) async throws {
        let client = try WorkspaceClient(server: server, persistSession: false)
        _ = try await client.csrfToken()
    }

    public func checkSession() async throws -> SessionUser? {
        let epoch = generation
        struct Session: Decodable { var user: SessionUser? }
        let result: Session = try await decoded(path: ["api", "auth", "session"])
        guard generation == epoch else { throw CancellationError() }
        if result.user == nil { try clearSession() }
        return result.user
    }

    public func login(email: String, password: String) async throws -> SessionUser {
        let epoch = generation
        let token = try await csrfToken()
        guard generation == epoch else { throw CancellationError() }
        let form = Self.formBody(["email": email, "password": password, "csrfToken": token, "json": "true", "callbackUrl": baseURL.absoluteString])
        let body: RemoteRecord
        do {
            body = try await decoded(path: ["api", "auth", "callback", "credentials"], method: "POST", body: form, contentType: "application/x-www-form-urlencoded")
        } catch WorkspaceClientError.unauthorized { throw WorkspaceClientError.invalidCredentials }
        guard generation == epoch else { throw CancellationError() }
        if let redirect = URLComponents(string: body.string("url")), redirect.queryItems?.contains(where: { $0.name == "error" }) == true {
            throw WorkspaceClientError.invalidCredentials
        }
        guard body["error"] == nil || body["error"] == .null else { throw WorkspaceClientError.invalidCredentials }
        guard let user = try await checkSession() else { throw WorkspaceClientError.invalidCredentials }
        return user
    }

    public func register(email: String, password: String) async throws {
        let _: RemoteRecord = try await decoded(path: ["api", "auth", "register"], method: "POST", json: ["email": .string(email), "password": .string(password)])
    }

    public func logout() async throws {
        let epoch = generation
        do {
            let token = try await csrfToken()
            guard generation == epoch else { throw CancellationError() }
            let _: RemoteRecord = try await decoded(path: ["api", "auth", "signout"], method: "POST", body: Self.formBody(["csrfToken": token, "json": "true"]), contentType: "application/x-www-form-urlencoded")
        } catch {
            if generation == epoch { try clearSession() }
            throw error
        }
        if generation == epoch { try clearSession() }
    }

    public func clearSession() throws {
        generation += 1
        cookies.removeAll()
        restored = true
        try secureStore?.remove(key: "cookies")
    }

    public func fetchOverview() async throws -> WorkspaceOverview { try await decoded(path: ["api", "workspace"]) }

    public func fetchWorkspace(agentId: String, conversationId: String? = nil, before: String? = nil) async throws -> WorkspaceAgent {
        var query: [URLQueryItem] = []
        if let id = conversationId {
            // Empty selects the draft/new conversation; absent resumes the server's active conversation.
            if !id.isEmpty { try Self.validateCursor(id) }
            query.append(URLQueryItem(name: "conversation_id", value: id))
        }
        if let before { try Self.validateCursor(before); query.append(URLQueryItem(name: "before", value: before)) }
        return try await decoded(path: ["api", "agents", agentId, "workspace"], query: query)
    }

    public func createConnection(name: String, urn: String) async throws -> RemoteRecord {
        try await decoded(path: ["api", "agents"], method: "POST", json: ["name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)), "urn": .string(urn.trimmingCharacters(in: .whitespacesAndNewlines))])
    }

    public func bindIdentity(agentId: String) async throws -> WorkspaceIdentity {
        try await decoded(path: ["api", "agents", agentId, "bind-owner"], method: "POST", json: [:])
    }

    public func selectConversation(agentId: String, conversationId: String?) async throws -> WorkspaceAgent {
        if let conversationId { try Self.validateCursor(conversationId) }
        return try await decoded(path: ["api", "agents", agentId, "workspace"], method: "POST", json: ["action": "select_conversation", "conversationId": conversationId.map(JSONValue.string) ?? .null])
    }

    public func dismissSubmission(agentId: String, requestId: String) async throws -> WorkspaceAgent {
        guard UUID(uuidString: requestId) != nil else { throw WorkspaceClientError.custom("请求编号无效。") }
        return try await decoded(path: ["api", "agents", agentId, "workspace"], method: "POST", json: ["action": "dismiss_submission", "requestId": .string(requestId)])
    }

    public func scheduleSync(agentId: String? = nil) async throws {
        let _: RemoteRecord = try await decoded(path: ["api", "workspace", "sync"], method: "POST", json: agentId.map { ["agentId": .string($0)] } ?? [:])
    }

    /// Retry with this same PendingCall. A timeout/cancel is never proof a send was rejected.
    public func execute(agentId: String, call: PendingCall) async throws -> RemoteRecord {
        let epoch = generation
        guard UUID(uuidString: call.requestId) != nil else { throw ControlCallError("请求编号无效。", call: call, retryable: false) }
        let send = call.method == .conversationSend
        let path = ["api", "agents", agentId, "control"]
        let deadline = Date().addingTimeInterval(executionTimeout)
        do {
            let payload = try call.encodeRequestBody()
            guard payload.count <= 32768 else { throw ControlCallError("内容过长，请缩短后发送。", call: call, retryable: false) }
            var body: RemoteRecord = try await decoded(path: path, method: "POST", body: payload, deadline: deadline)
            var attempts = 0
            while body.string("status") == "pending" && attempts < maximumPolls && Date() < deadline {
                guard generation == epoch else { throw CancellationError() }
                try validateRequestId(body, call: call)
                let remaining = max(0, deadline.timeIntervalSinceNow)
                try await Task.sleep(nanoseconds: min(pollingInterval, UInt64(remaining * 1_000_000_000)))
                try Task.checkCancellation()
                guard generation == epoch else { throw CancellationError() }
                guard Date() < deadline else { break }
                body = try await decoded(path: path, query: [URLQueryItem(name: "request_id", value: call.requestId)], deadline: deadline)
                attempts += 1
            }
            guard generation == epoch else { throw CancellationError() }
            try validateRequestId(body, call: call)
            guard body.string("status") == "complete" else {
                throw ControlCallError("尚未收到 agent 的有效响应。已提交的动作可能仍在处理，请核实同一次请求的结果。", call: call, retryable: body.string("status") != "expired", uncertain: send)
            }
            let response = body.record("response")
            guard response.string("request_id") == call.requestId, response.string("method") == call.method.rawValue,
                  response.string("protocol") == "agent-comm-control/v1", response.string("type") == "response",
                  (response["result"] != nil) != (response["error"] != nil) else {
                throw ControlCallError("返回内容与本次请求不匹配，尚不能确认结果。", call: call, uncertain: send)
            }
            if let rawError = response["error"] {
                guard let error = rawError.objectValue, !error.string("code").isEmpty, !error.string("message").isEmpty else {
                    throw ControlCallError("Agent 返回了无效的错误内容，尚不能确认结果。", call: call, uncertain: send)
                }
                throw ControlCallError(Self.remoteErrors[error.string("code")] ?? error.string("message"), call: call, retryable: false, uncertain: false)
            }
            guard let result = response["result"]?.objectValue else {
                throw ControlCallError("Agent 返回了无法识别的结果。", call: call, uncertain: send)
            }
            return result
        } catch is CancellationError { throw CancellationError() }
        catch let error as ControlCallError { throw error }
        catch {
            if Task.isCancelled { throw CancellationError() }
            let status: Int?
            if case WorkspaceClientError.unauthorized = error { status = 401 }
            else if case WorkspaceClientError.serverError(let code) = error { status = code }
            else if let failure = error as? HTTPFailure { status = failure.status }
            else { status = nil }
            let terminal = status.map { [400, 401, 403, 404, 410, 413].contains($0) } ?? false
            throw ControlCallError(error.localizedDescription, call: call, retryable: !terminal, uncertain: send, httpStatus: status)
        }
    }

    private func validateRequestId(_ body: RemoteRecord, call: PendingCall) throws {
        guard body.string("request_id") == call.requestId else {
            throw ControlCallError("返回内容与本次请求不匹配，尚不能确认结果。", call: call, uncertain: call.method == .conversationSend)
        }
    }

    private static let remoteErrors: [String: String] = [
        "not_paired": "这个控制台尚未配对，或本机配对已过期。请在 agent 本机检查授权后重试。",
        "owner_mismatch": "本机配对属于另一个 agent 配置，请检查配对时选择的配置。",
        "method_not_allowed": "本机配对没有开放这项功能，请检查授权范围。",
        "unsupported_method": "这个 agent 暂不支持这项功能。",
        "queue_full": "Agent 正在处理较多消息，请等待已有回合结束。",
        "result_too_large": "返回内容过多，请指定一个事项或对话后重新读取。"
    ]

    private nonisolated static func validateCursor(_ cursor: String) throws {
        guard cursor.range(of: "^[A-Za-z0-9._:-]{1,128}$", options: .regularExpression) != nil else {
            throw WorkspaceClientError.custom("对话或翻页编号无效。")
        }
    }

    private func csrfToken() async throws -> String {
        let data: RemoteRecord = try await decoded(path: ["api", "auth", "csrf"])
        let token = data.string("csrfToken")
        guard !token.isEmpty else { throw WorkspaceClientError.invalidResponse }
        return token
    }

    public nonisolated static func formBody(_ fields: [String: String]) -> Data {
        // RFC 3986 unreserved characters; +, &, = and Unicode are encoded as UTF-8 bytes.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let text = fields.sorted { $0.key < $1.key }.map { key, value in
            (key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&")
        return Data(text.utf8)
    }

    private func decoded<T: Decodable>(path: [String], method: String = "GET", query: [URLQueryItem] = [], json: RemoteRecord? = nil,
                                       body: Data? = nil, contentType: String = "application/json", deadline: Date? = nil) async throws -> T {
        try Task.checkCancellation()
        try restoreCookies()
        let epoch = generation
        var url = baseURL
        for component in path {
            guard !component.isEmpty, !component.contains("/"), component != ".", component != ".." else { throw WorkspaceClientError.invalidURL }
            url.appendPathComponent(component)
        }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        guard let target = parts.url else { throw WorkspaceClientError.invalidURL }
        var request = URLRequest(url: target)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let remaining = deadline?.timeIntervalSinceNow ?? 30
        guard remaining > 0 else { throw URLError(.timedOut) }
        request.timeoutInterval = min(30, remaining)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if method != "GET" {
            request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = try json.map { try JSONEncoder().encode($0) } ?? body
        let applicable = cookies.filter { cookie in
            (cookie.expiresDate.map { $0 > Date() } ?? true) && (!cookie.isSecure || target.scheme == "https") && target.path.hasPrefix(cookie.path)
        }
        for (name, value) in HTTPCookie.requestHeaderFields(with: applicable) { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard generation == epoch else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse, http.url?.host == baseURL.host, http.url?.scheme == baseURL.scheme,
              http.url?.port == baseURL.port else { throw WorkspaceClientError.invalidResponse }
        try captureCookies(http)
        if http.statusCode == 401 { throw WorkspaceClientError.unauthorized }
        guard (200...299).contains(http.statusCode) else {
            if let object = try? JSONDecoder().decode(RemoteRecord.self, from: data), !object.string("error").isEmpty {
                throw HTTPFailure(status: http.statusCode, message: object.string("error"))
            }
            throw WorkspaceClientError.serverError(http.statusCode)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw WorkspaceClientError.invalidResponse }
    }

    private struct CookieRecord: Codable {
        var name: String; var value: String; var domain: String; var path: String
        var secure: Bool; var httpOnly: Bool; var expires: Date?
        init(_ cookie: HTTPCookie) {
            name = cookie.name; value = cookie.value; domain = cookie.domain; path = cookie.path
            secure = cookie.isSecure; httpOnly = cookie.isHTTPOnly; expires = cookie.expiresDate
        }
        var cookie: HTTPCookie? {
            var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
            if secure { properties[.secure] = "TRUE" }
            if httpOnly { properties[HTTPCookiePropertyKey(rawValue: "HttpOnly")] = "TRUE" }
            if let expires { properties[.expires] = expires }
            return HTTPCookie(properties: properties)
        }
    }

    private func restoreCookies() throws {
        guard !restored else { return }
        if let saved = try secureStore?.data(key: "cookies") {
            let records = (try? JSONDecoder().decode([CookieRecord].self, from: saved)) ?? []
            cookies = records.compactMap(\.cookie).filter(validCookie)
        }
        restored = true
    }

    private func validCookie(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let host = (baseURL.host ?? "").lowercased()
        return (domain == host || host.hasSuffix("." + domain)) && (cookie.expiresDate.map { $0 > Date() } ?? true) && (!cookie.isSecure || baseURL.scheme == "https")
    }

    private func captureCookies(_ response: HTTPURLResponse) throws {
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String { result[key] = String(describing: pair.value) }
        }
        let incoming = HTTPCookie.cookies(withResponseHeaderFields: headers, for: baseURL)
        guard !incoming.isEmpty else { return }
        for cookie in incoming {
            cookies.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
            if validCookie(cookie) { cookies.append(cookie) }
        }
        cookies = cookies.filter(validCookie)
        try secureStore?.set(JSONEncoder().encode(cookies.map(CookieRecord.init)), for: "cookies")
    }
}

private struct HTTPFailure: Error, LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // All API endpoints are JSON endpoints. Refuse redirects, including HTTPS downgrades.
        completionHandler(nil)
    }
}
