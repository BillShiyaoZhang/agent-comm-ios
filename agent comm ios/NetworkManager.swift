import Foundation
import Combine

enum NetworkError: Error, LocalizedError {
    case invalidURL
    case invalidCredentials
    case unauthorized
    case serverError(Int)
    case custom(String)
    case unknown
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid server URL."
        case .invalidCredentials: return "Invalid email or password."
        case .unauthorized: return "Unauthorized access. Please log in again."
        case .serverError(let code): return "Server returned error code \(code)."
        case .custom(let message): return message
        case .unknown: return "An unknown error occurred."
        }
    }
}

struct APIErrorResponse: Codable {
    let error: String?
}

class NetworkManager: ObservableObject {
    static let shared = NetworkManager()
    
    @Published var baseUrl: String {
        didSet {
            UserDefaults.standard.set(baseUrl, forKey: "agent_collab_base_url")
            saveCookies() // Ensure cookies are clean for new URL
        }
    }
    
    @Published var currentUser: User? = nil
    @Published var isAuthenticated = false
    @Published var isCheckingSession = false
    
    private var session: URLSession
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        // Retrieve base URL, default to localhost
        let savedUrl = UserDefaults.standard.string(forKey: "agent_collab_base_url")
        self.baseUrl = savedUrl ?? "http://localhost:3000"
        
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        self.session = URLSession(configuration: config)
        
        restoreCookies()
    }
    
    // MARK: - Core Utilities
    func getURL(_ path: String) -> URL? {
        var cleanBase = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanBase.lowercased().hasPrefix("http://") && !cleanBase.lowercased().hasPrefix("https://") {
            cleanBase = "http://" + cleanBase
        }
        // Remove trailing slash
        if cleanBase.hasSuffix("/") {
            cleanBase.removeLast()
        }
        return URL(string: cleanBase + path)
    }
    
    private func percentEncode(_ string: String) -> String {
        return string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? string
    }
    
    // MARK: - Cookie Storage Persistence
    func saveCookies() {
        guard let url = getURL("/"),
              let cookies = HTTPCookieStorage.shared.cookies(for: url) else { return }
        
        var cookieDictArray: [[String: Any]] = []
        for cookie in cookies {
            var properties: [String: Any] = [:]
            properties[HTTPCookiePropertyKey.name.rawValue] = cookie.name
            properties[HTTPCookiePropertyKey.value.rawValue] = cookie.value
            properties[HTTPCookiePropertyKey.domain.rawValue] = cookie.domain
            properties[HTTPCookiePropertyKey.path.rawValue] = cookie.path
            properties[HTTPCookiePropertyKey.version.rawValue] = cookie.version
            if let expiresDate = cookie.expiresDate {
                properties[HTTPCookiePropertyKey.expires.rawValue] = expiresDate
            }
            cookieDictArray.append(properties)
        }
        
        UserDefaults.standard.set(cookieDictArray, forKey: "agent_collab_saved_cookies")
    }
    
    func restoreCookies() {
        guard let cookieDictArray = UserDefaults.standard.array(forKey: "agent_collab_saved_cookies") as? [[String: Any]] else { return }
        
        for properties in cookieDictArray {
            var convertedProperties: [HTTPCookiePropertyKey: Any] = [:]
            for (key, val) in properties {
                convertedProperties[HTTPCookiePropertyKey(rawValue: key)] = val
            }
            if let cookie = HTTPCookie(properties: convertedProperties) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }
    }
    
    func clearCookies() {
        if let url = getURL("/") {
            if let cookies = HTTPCookieStorage.shared.cookies(for: url) {
                for cookie in cookies {
                    HTTPCookieStorage.shared.deleteCookie(cookie)
                }
            }
        }
        UserDefaults.standard.removeObject(forKey: "agent_collab_saved_cookies")
    }
    
    // MARK: - Auth API
    func checkSession() async throws {
        guard let url = getURL("/api/auth/session") else {
            throw NetworkError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            DispatchQueue.main.async {
                self.currentUser = nil
                self.isAuthenticated = false
            }
            return
        }
        
        // NextAuth /api/auth/session returns empty json {} if not logged in
        if data.count <= 2 { // "{}" is 2 bytes
            DispatchQueue.main.async {
                self.currentUser = nil
                self.isAuthenticated = false
            }
            return
        }
        
        struct NextAuthSession: Codable {
            struct SessionUser: Codable {
                let id: String
                let email: String
                let name: String?
            }
            let user: SessionUser?
        }
        
        do {
            let sessionRes = try JSONDecoder().decode(NextAuthSession.self, from: data)
            if let userObj = sessionRes.user {
                // Fetch the complete User profile if needed, or build virtual User profile
                let virtualUser = User(
                    id: userObj.id,
                    email: userObj.email,
                    virtualUrn: nil,
                    virtualEd25519PublicKey: nil,
                    virtualX25519PublicKey: nil,
                    createdAt: "",
                    updatedAt: ""
                )
                DispatchQueue.main.async {
                    self.currentUser = virtualUser
                    self.isAuthenticated = true
                }
                self.saveCookies()
            } else {
                DispatchQueue.main.async {
                    self.currentUser = nil
                    self.isAuthenticated = false
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.currentUser = nil
                self.isAuthenticated = false
            }
        }
    }
    
    func login(email: String, password: String) async throws {
        // 1. Get CSRF Token
        guard let csrfUrl = getURL("/api/auth/csrf") else {
            throw NetworkError.invalidURL
        }
        
        struct CsrfResponse: Codable {
            let csrfToken: String
        }
        
        let (csrfData, csrfResponse) = try await session.data(from: csrfUrl)
        guard let httpCsrf = csrfResponse as? HTTPURLResponse, httpCsrf.statusCode == 200 else {
            let statusCode = (csrfResponse as? HTTPURLResponse)?.statusCode ?? 0
            throw NetworkError.serverError(statusCode)
        }
        
        let csrfRes = try JSONDecoder().decode(CsrfResponse.self, from: csrfData)
        let csrfToken = csrfRes.csrfToken
        
        // 2. Post callback credentials
        guard let callbackUrl = getURL("/api/auth/callback/credentials") else {
            throw NetworkError.invalidURL
        }
        
        var request = URLRequest(url: callbackUrl)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let bodyString = "email=\(percentEncode(email))&password=\(percentEncode(password))&csrfToken=\(percentEncode(csrfToken))&json=true"
        request.httpBody = bodyString.data(using: .utf8)
        
        let (loginData, loginResponse) = try await session.data(for: request)
        guard let httpLogin = loginResponse as? HTTPURLResponse else {
            throw NetworkError.unknown
        }
        
        if httpLogin.statusCode != 200 {
            throw NetworkError.invalidCredentials
        }
        
        // If login response returns error parameter in redirection url or body
        let responseBody = String(data: loginData, encoding: .utf8) ?? ""
        if responseBody.contains("error=") || responseBody.contains("CredentialsSignin") {
            throw NetworkError.invalidCredentials
        }
        
        // Verify session successfully set cookie
        try await checkSession()
        
        if !isAuthenticated {
            throw NetworkError.invalidCredentials
        }
    }
    
    func register(email: String, password: String) async throws {
        guard let registerUrl = getURL("/api/auth/register") else {
            throw NetworkError.invalidURL
        }
        
        var request = URLRequest(url: registerUrl)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        struct RegisterBody: Codable {
            let email: String
            let password: String
        }
        
        let body = RegisterBody(email: email, password: password)
        request.httpBody = try JSONEncoder().encode(body)
        
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.unknown
        }
        
        if httpResponse.statusCode != 200 && httpResponse.statusCode != 201 {
            if let errRes = try? JSONDecoder().decode(APIErrorResponse.self, from: data), let errMsg = errRes.error {
                throw NetworkError.custom(errMsg)
            }
            throw NetworkError.serverError(httpResponse.statusCode)
        }
    }
    
    func logout() async throws {
        // NextAuth signout
        guard let signoutUrl = getURL("/api/auth/signout") else {
            throw NetworkError.invalidURL
        }
        
        // 1. Get CSRF Token for signout
        struct CsrfResponse: Codable {
            let csrfToken: String
        }
        let (csrfData, _) = try await session.data(from: getURL("/api/auth/csrf")!)
        let csrfRes = try JSONDecoder().decode(CsrfResponse.self, from: csrfData)
        
        // 2. Post signout callback
        var request = URLRequest(url: signoutUrl)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let bodyString = "csrfToken=\(percentEncode(csrfRes.csrfToken))&json=true"
        request.httpBody = bodyString.data(using: .utf8)
        
        _ = try await session.data(for: request)
        
        // 3. Clear local states
        clearCookies()
        DispatchQueue.main.async {
            self.currentUser = nil
            self.isAuthenticated = false
        }
    }
    
    // MARK: - Authenticated Request Helper
    private func performRequest<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        guard let url = getURL(path) else {
            throw NetworkError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        
        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.unknown
        }
        
        if httpResponse.statusCode == 401 {
            DispatchQueue.main.async {
                self.isAuthenticated = false
                self.currentUser = nil
            }
            throw NetworkError.unauthorized
        }
        
        guard httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 else {
            if let errRes = try? JSONDecoder().decode(APIErrorResponse.self, from: data), let errMsg = errRes.error {
                throw NetworkError.custom(errMsg)
            }
            throw NetworkError.serverError(httpResponse.statusCode)
        }
        
        return try JSONDecoder().decode(T.self, from: data)
    }
    
    // MARK: - Agents endpoints
    func fetchAgents() async throws -> [Agent] {
        return try await performRequest("/api/agents")
    }
    
    func createAgent(mode: String, name: String, password: String?, urn: String?, publicKey: String?, localUrl: String?) async throws -> Agent {
        struct CreateAgentBody: Codable {
            let mode: String
            let name: String
            let password: String?
            let urn: String?
            let publicKey: String?
            let localUrl: String?
        }
        let body = CreateAgentBody(mode: mode, name: name, password: password, urn: urn, publicKey: publicKey, localUrl: localUrl)
        let bodyData = try JSONEncoder().encode(body)
        return try await performRequest("/api/agents", method: "POST", body: bodyData)
    }
    
    func registerAgentToPlatform(agentId: String) async throws -> Agent {
        return try await performRequest("/api/agents/\(agentId)/register", method: "POST")
    }
    
    // MARK: - Contacts endpoints
    func fetchContacts() async throws -> [Contact] {
        return try await performRequest("/api/contacts")
    }
    
    func createContact(agentId: String, contactUrn: String, trustTier: String, alias: String?, publicKey: String?) async throws -> Contact {
        struct CreateContactBody: Codable {
            let agentId: String
            let contactUrn: String
            let trustTier: String
            let alias: String?
            let publicKey: String?
        }
        let body = CreateContactBody(agentId: agentId, contactUrn: contactUrn, trustTier: trustTier, alias: alias, publicKey: publicKey)
        let bodyData = try JSONEncoder().encode(body)
        return try await performRequest("/api/contacts", method: "POST", body: bodyData)
    }
    
    // MARK: - Messages endpoints
    func fetchMessages(agentId: String?, contactUrn: String?) async throws -> [Message] {
        var path = "/api/messages"
        var queryItems: [URLQueryItem] = []
        if let agentId = agentId {
            queryItems.append(URLQueryItem(name: "agentId", value: agentId))
        }
        if let contactUrn = contactUrn {
            queryItems.append(URLQueryItem(name: "contactUrn", value: contactUrn))
        }
        
        if !queryItems.isEmpty {
            var components = URLComponents()
            components.queryItems = queryItems
            if let queryString = components.percentEncodedQuery {
                path += "?" + queryString
            }
        }
        
        return try await performRequest(path)
    }
    
    func sendMessage(agentId: String, recipientUrn: String, content: String) async throws -> Message {
        struct SendMessageBody: Codable {
            let agentId: String
            let recipientUrn: String
            let content: String
        }
        
        struct SendMessageResponse: Codable {
            let message: Message
        }
        
        let body = SendMessageBody(agentId: agentId, recipientUrn: recipientUrn, content: content)
        let bodyData = try JSONEncoder().encode(body)
        
        // Web returns { message: Message, hitlRequest: HITLRequest? }
        let res: SendMessageResponse = try await performRequest("/api/messages", method: "POST", body: bodyData)
        return res.message
    }
    
    // MARK: - HITL endpoints
    func fetchHITLRequests() async throws -> [HITLRequest] {
        return try await performRequest("/api/hitl")
    }
    
    func resolveHITLRequest(id: String, action: String) async throws -> HITLRequest {
        struct ResolveBody: Codable {
            let action: String // approve, reject
        }
        let body = ResolveBody(action: action)
        let bodyData = try JSONEncoder().encode(body)
        return try await performRequest("/api/hitl/\(id)", method: "PATCH", body: bodyData)
    }
    
    // MARK: - Service Call (Oncall) endpoints
    func fetchServices(targetUrn: String) async throws -> [ServiceDescription] {
        let path = "/api/oncall?targetUrn=\(percentEncode(targetUrn))"
        return try await performRequest(path)
    }
    
    func invokeService(agentId: String, targetUrn: String, serviceName: String, args: [String: Any]) async throws -> HITLRequest {
        // Need to manually build request since arguments contains type-erased Any dictionary
        guard let url = getURL("/api/oncall") else {
            throw NetworkError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let bodyDict: [String: Any] = [
            "agentId": agentId,
            "targetUrn": targetUrn,
            "serviceName": serviceName,
            "args": args
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict, options: [])
        
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.unknown
        }
        
        if httpResponse.statusCode == 401 {
            DispatchQueue.main.async {
                self.isAuthenticated = false
                self.currentUser = nil
            }
            throw NetworkError.unauthorized
        }
        
        guard httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 else {
            throw NetworkError.serverError(httpResponse.statusCode)
        }
        
        struct InvokeResponse: Codable {
            let success: Bool
            let hitlRequest: HITLRequest
        }
        
        let res = try JSONDecoder().decode(InvokeResponse.self, from: data)
        return res.hitlRequest
    }
    
    // MARK: - Transactions endpoints
    func fetchTransactions() async throws -> [Transaction] {
        return try await performRequest("/api/transactions")
    }
    
    func createTransaction(agentId: String, recipientUrn: String, amount: String, memo: String) async throws -> Transaction {
        struct CreateTxBody: Codable {
            let agentId: String
            let recipientUrn: String
            let amount: String
            let memo: String
        }
        let body = CreateTxBody(agentId: agentId, recipientUrn: recipientUrn, amount: amount, memo: memo)
        let bodyData = try JSONEncoder().encode(body)
        return try await performRequest("/api/transactions", method: "POST", body: bodyData)
    }
}
