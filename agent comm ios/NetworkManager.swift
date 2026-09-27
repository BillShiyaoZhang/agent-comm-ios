import Foundation
import Combine
import AgentWorkspaceKit

typealias NetworkError = WorkspaceClientError

/// UI-facing session state. Transport, authentication and wire models live in AgentWorkspaceKit.
@MainActor
final class NetworkManager: ObservableObject {
    static let shared = NetworkManager()

    @Published private(set) var baseUrl: String
    @Published private(set) var currentUser: User?
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isCheckingSession = false
    private var client: WorkspaceClient
    private var generation = 0
    var sessionRevision: Int { generation }

    private init() {
        // Legacy releases wrote bearer cookies to preferences. Never restore that insecure cache.
        UserDefaults.standard.removeObject(forKey: "agent_collab_saved_cookies")
        let saved = UserDefaults.standard.string(forKey: "agent_collab_base_url") ?? "https://agent-communication.online"
        let normalized = (try? WorkspaceClient.validateServer(saved).absoluteString) ?? "https://agent-communication.online"
        baseUrl = normalized
        client = try! WorkspaceClient(server: normalized)
    }

    func configureServer(_ server: String) throws {
        let replacement = try WorkspaceClient(server: server)
        let normalized = replacement.baseURL.absoluteString
        guard normalized != baseUrl else { return }
        generation += 1
        client = replacement
        baseUrl = normalized
        currentUser = nil
        isAuthenticated = false
        isCheckingSession = false
        UserDefaults.standard.set(normalized, forKey: "agent_collab_base_url")
    }

    func testConnection(server: String) async throws {
        try await WorkspaceClient.testConnection(server: server)
    }

    func checkSession() async throws {
        let epoch = generation
        isCheckingSession = true
        defer { if generation == epoch { isCheckingSession = false } }
        let user = try await perform { try await $0.checkSession() }
        guard generation == epoch else { throw CancellationError() }
        currentUser = user
        isAuthenticated = user != nil
    }

    func login(email: String, password: String) async throws {
        generation += 1
        let epoch = generation
        currentUser = nil
        isAuthenticated = false
        isCheckingSession = true
        defer { if generation == epoch { isCheckingSession = false } }
        let user = try await perform { client in
            try await client.clearSession()
            return try await client.login(email: email, password: password)
        }
        guard generation == epoch else { throw CancellationError() }
        currentUser = user
        isAuthenticated = true
    }

    func register(email: String, password: String) async throws {
        try await perform { try await $0.register(email: email, password: password) }
    }

    func logout() async throws {
        let previous = client
        generation += 1
        currentUser = nil
        isAuthenticated = false
        isCheckingSession = false
        try await previous.logout()
    }

    func fetchOverview() async throws -> WorkspaceOverview {
        try await perform { try await $0.fetchOverview() }
    }

    func fetchWorkspace(agentId: String, conversationId: String? = nil, before: String? = nil) async throws -> WorkspaceAgent {
        try await perform { try await $0.fetchWorkspace(agentId: agentId, conversationId: conversationId, before: before) }
    }

    func createConnection(name: String, urn: String) async throws -> RemoteRecord {
        try await perform { try await $0.createConnection(name: name, urn: urn) }
    }

    func bindIdentity(agentId: String) async throws -> WorkspaceIdentity {
        try await perform { try await $0.bindIdentity(agentId: agentId) }
    }

    func selectConversation(agentId: String, conversationId: String?) async throws -> WorkspaceAgent {
        try await perform { try await $0.selectConversation(agentId: agentId, conversationId: conversationId) }
    }

    func scheduleSync(agentId: String? = nil) async throws {
        try await perform { try await $0.scheduleSync(agentId: agentId) }
    }

    func execute(agentId: String, call: PendingCall) async throws -> RemoteRecord {
        try await perform { try await $0.execute(agentId: agentId, call: call) }
    }

    func dismissSubmission(agentId: String, requestId: String) async throws -> WorkspaceAgent {
        try await perform { try await $0.dismissSubmission(agentId: agentId, requestId: requestId) }
    }

    func fetchPolicy() async throws -> RemoteRecord { try await perform { try await $0.fetchPolicy() } }
    func updatePolicy(_ body: RemoteRecord) async throws -> RemoteRecord { try await perform { try await $0.updatePolicy(body) } }
    func pausePolicy() async throws { _ = try await perform { try await $0.pausePolicy() } }
    func fetchNotifications(filter: String = "all", before: Double? = nil) async throws -> RemoteRecord {
        try await perform { try await $0.fetchNotifications(filter: filter, before: before) }
    }
    func markNotificationRead(agentId: String, id: String, revision: Int) async throws {
        try await perform { try await $0.markNotificationRead(agentId: agentId, id: id, revision: revision) }
    }
    func fetchOperations(agentId: String) async throws -> [WorkspaceOperation] {
        try await perform { try await $0.fetchOperations(agentId: agentId) }
    }
    func reserveOperation(agentId: String, call: PendingCall, conversationId: String? = nil) async throws -> WorkspaceOperation {
        try await perform { try await $0.reserveOperation(agentId: agentId, call: call, conversationId: conversationId) }
    }
    func updateOperation(agentId: String, requestId: String, phase: String, message: String, retryable: Bool) async throws -> WorkspaceOperation {
        try await perform { try await $0.updateOperation(agentId: agentId, requestId: requestId, phase: phase, message: message, retryable: retryable) }
    }
    func fetchConversations(agentId: String, query: String = "", archived: String = "active", deleted: String = "active", before: String? = nil) async throws -> RemoteRecord {
        try await perform { try await $0.fetchConversations(agentId: agentId, query: query, archived: archived, deleted: deleted, before: before) }
    }
    func updateConversation(agentId: String, conversationId: String?, patch: RemoteRecord) async throws -> RemoteRecord {
        try await perform { try await $0.updateConversation(agentId: agentId, conversationId: conversationId, patch: patch) }
    }
    func renameConnection(agentId: String, name: String) async throws { try await perform { try await $0.renameConnection(agentId: agentId, name: name) } }
    func removeConnection(agentId: String) async throws { try await perform { try await $0.removeConnection(agentId: agentId) } }
    func saveRecordState(agentId: String, kind: String, id: String, deleted: Bool) async throws -> WorkspaceRecordState {
        try await perform { try await $0.saveRecordState(agentId: agentId, kind: kind, id: id, deleted: deleted) }
    }
    func fetchActivity() async throws -> RemoteRecord { try await perform { try await $0.fetchActivity() } }
    func fetchAccount() async throws -> RemoteRecord { try await perform { try await $0.fetchAccount() } }
    func resendVerification(email: String) async throws { _ = try await perform { try await $0.resendVerification(email: email) } }
    func requestPasswordReset(email: String) async throws { _ = try await perform { try await $0.requestPasswordReset(email: email) } }
    func changePassword(currentPassword: String, password: String) async throws -> RemoteRecord {
        try await perform { try await $0.changePassword(currentPassword: currentPassword, password: password) }
    }
    func previewOnboarding(code: String) async throws -> RemoteRecord { try await perform { try await $0.previewOnboarding(code: code) } }
    func approveOnboarding(code: String) async throws -> RemoteRecord { try await perform { try await $0.approveOnboarding(code: code) } }

    private func perform<T>(_ operation: (WorkspaceClient) async throws -> T) async throws -> T {
        let epoch = generation
        let active = client
        do {
            let result = try await operation(active)
            guard generation == epoch else { throw CancellationError() }
            return result
        } catch {
            // A delayed response from another account/server must not affect this session.
            guard generation == epoch else { throw CancellationError() }
            let unauthorized: Bool
            if case WorkspaceClientError.unauthorized = error { unauthorized = true }
            else { unauthorized = (error as? ControlCallError)?.httpStatus == 401 }
            if unauthorized {
                generation += 1
                currentUser = nil
                isAuthenticated = false
                isCheckingSession = false
                try? await active.clearSession()
            }
            throw error
        }
    }
}
