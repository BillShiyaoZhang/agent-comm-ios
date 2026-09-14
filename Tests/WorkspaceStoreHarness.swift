import Foundation
import Combine
import CryptoKit
import AgentWorkspaceKit

// Shadows only the app store's journal dependency. Production Keychain code remains untouched.
final class SecureStore {
    static var memory: [String: Data] = [:]
    static var failReads = false
    private let namespace: String
    init(namespace: String) { self.namespace = namespace }
    func data(key: String) throws -> Data? {
        if Self.failReads { throw HarnessFailure.message("Journal is temporarily unavailable") }
        return Self.memory[namespace + ":" + key]
    }
    func set(_ data: Data, for key: String) throws { Self.memory[namespace + ":" + key] = data }
    func remove(key: String) throws { Self.memory.removeValue(forKey: namespace + ":" + key) }
}

@MainActor
final class NetworkManager: ObservableObject {
    static let shared = NetworkManager()
    @Published var baseUrl = "https://test.invalid"
    @Published var currentUser: SessionUser? = SessionUser(id: "test", email: "test@example.com")
    @Published var isAuthenticated = true
    var sessionRevision = 0
    var workspaces: [String: WorkspaceAgent] = [:]
    var overviewIDs: [String] = []
    var reads: [(agent: String, conversation: String?, before: String?)] = []
    var requests: [(account: String, method: String)] = []
    var calls: [PendingCall] = []
    var executeHandler: ((String, PendingCall) async throws -> RemoteRecord)?
    var fetchHandler: ((String, String?, String?) async throws -> WorkspaceAgent)?
    var selectHandler: ((String, String?) async throws -> WorkspaceAgent)?

    func reset(_ account: String) {
        sessionRevision += 1
        currentUser = SessionUser(id: account, email: account + "@example.com")
        isAuthenticated = true
        workspaces = [:]; overviewIDs = []; reads = []; requests = []; calls = []
        executeHandler = nil; fetchHandler = nil; selectHandler = nil
        SecureStore.memory = [:]
        SecureStore.failReads = false
    }
    private func record(_ method: String) { requests.append((currentUser?.id ?? "signed-out", method)) }
    func fetchOverview() async throws -> WorkspaceOverview {
        record("overview")
        return WorkspaceOverview(connections: overviewIDs.compactMap { workspaces[$0]?.agent })
    }
    func fetchWorkspace(agentId: String, conversationId: String? = nil, before: String? = nil) async throws -> WorkspaceAgent {
        record("workspace")
        reads.append((agentId, conversationId, before))
        if let fetchHandler { return try await fetchHandler(agentId, conversationId, before) }
        guard var result = workspaces[agentId] else { throw HarnessFailure.message("Missing fixture " + agentId) }
        if let conversationId {
            result.activeConversationId = conversationId
            if result.conversation?.string("conversation_id") != conversationId { result.conversation = nil }
        }
        return result
    }
    func scheduleSync(agentId: String?) async throws { record("sync") }
    func execute(agentId: String, call: PendingCall) async throws -> RemoteRecord {
        record("execute"); calls.append(call)
        if let executeHandler { return try await executeHandler(agentId, call) }
        return [:]
    }
    func createConnection(name: String, urn: String) async throws -> RemoteRecord { ["id": .string("created")] }
    func bindIdentity(agentId: String) async throws -> WorkspaceIdentity { workspaces[agentId]!.identity }
    func selectConversation(agentId: String, conversationId: String?) async throws -> WorkspaceAgent {
        record("selection")
        if let selectHandler { return try await selectHandler(agentId, conversationId) }
        workspaces[agentId]?.activeConversationId = conversationId ?? ""
        return try await fetchWorkspace(agentId: agentId, conversationId: conversationId ?? "")
    }
    func dismissSubmission(agentId: String, requestId: String) async throws -> WorkspaceAgent {
        workspaces[agentId]?.submission = nil
        return try await fetchWorkspace(agentId: agentId)
    }
}

@MainActor
final class Gate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
    func waitUntilEntered() async throws {
        for _ in 0..<10_000 {
            if entered { return }
            await Task.yield()
        }
        throw HarnessFailure.message("Async gate was never reached")
    }
}

enum HarnessFailure: Error {
    case message(String)
}

@main
@MainActor
struct WorkspaceStoreHarness {
    static let network = NetworkManager.shared
    static var failures = 0

    static func main() async {
        await test("uncached agent restores its saved active conversation", uncachedAgentResumes)
        await test("in-flight send keeps its agent and writes its journal first", agentRemovalDuringSend)
        await test("uncertain send survives recreation and retries the same request", recoverUncertainSubmission)
        await test("accepted local submission resolves before a newer remote submission", reconcileBeforeRemoteSubmission)
        await test("unverified local submission survives an unrelated remote submission", preserveUnverifiedLocalSubmission)
        await test("unreadable recovery journal blocks sending until restored", unreadableRecoveryJournal)
        await test("accepted new conversation survives an empty server cache", preserveNewConversation)
        await test("older cache reads preserve terminal turns and loaded history", preservePaginatedTranscript)
        await test("remote-only conversation is fetched before saved selection", openRemoteConversation)
        await test("same account re-login invalidates old store operations", sameAccountRelogin)
        await test("polling preserves action errors and separately clears connection errors", preserveActionErrors)
        await test("old account operations stop after account changes", accountChangesDuringSend)
        if failures > 0 { exit(1) }
        print("All workspace store regressions passed.")
    }

    static func test(_ name: String, _ operation: () async throws -> Void) async {
        do { try await operation(); print("PASS: " + name) }
        catch { failures += 1; print("FAIL: " + name + " — " + String(describing: error)) }
    }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw HarnessFailure.message(message) }
    }
    static func fixture(_ id: String, conversation: String? = nil) -> WorkspaceAgent {
        let conversation = conversation ?? "conversation-" + id
        return WorkspaceAgent(
            agent: WorkspaceConnection(id: id, name: id, urn: "urn:agent:" + id),
            identity: WorkspaceIdentity(virtualUrn: "urn:virtual:test"),
            sync: WorkspaceSync(status: "ready"),
            snapshots: ["capabilities": WorkspaceSnapshot(data: ["methods": .array([.object(["name": .string("conversation.send"), "available": .bool(true)])])], time: 100)],
            activeConversationId: conversation,
            conversation: ["conversation_id": .string(conversation), "turns": .array([])]
        )
    }
    static func seed(_ account: String, ids: [String] = ["a"]) {
        network.reset(account)
        network.overviewIDs = ids
        for id in ids { network.workspaces[id] = fixture(id) }
    }
    static func receipt(_ call: PendingCall) -> RemoteRecord {
        let hash = SHA256.hash(data: Data(("urn:virtual:test\u{0}" + call.requestId).utf8)).map { String(format: "%02x", $0) }.joined()
        return ["status": .string("submitted"), "conversation_id": .string(call.params.string("conversation_id").isEmpty ? call.requestId : call.params.string("conversation_id")), "turn_id": .string("turn-" + hash.prefix(40))]
    }
    static func journalEntries() -> [Data] {
        SecureStore.memory.filter { $0.key.contains(":submission.") }.map(\.value)
    }
    static func turn(_ id: String, time: Double, status: String) -> RemoteRecord {
        ["turn_id": .string(id), "created_at": .number(time), "status": .string(status), "text": .string(id)]
    }

    static func uncachedAgentResumes() async throws {
        seed("resume", ids: ["a", "b"])
        let store = WorkspaceStore()
        await store.refresh()
        await store.selectAgent("b")
        try expect(store.conversationID == "conversation-b", "Uncached agent incorrectly opens a new conversation")
        try expect(network.reads.last?.conversation == nil, "Initial agent read must omit conversation_id")
    }

    static func agentRemovalDuringSend() async throws {
        seed("agent-removal", ids: ["a", "b"])
        let store = WorkspaceStore()
        await store.refresh()
        store.draft = "Original agent message"
        let gate = Gate()
        var journalWasWritten = false
        network.executeHandler = { _, call in
            journalWasWritten = journalEntries().contains { (try? JSONDecoder().decode(WorkspaceSubmission.self, from: $0).call.requestId) == call.requestId }
            await gate.wait()
            return receipt(call)
        }
        let sending = Task { await store.send() }
        try await gate.waitUntilEntered()
        network.overviewIDs = ["b"]
        await store.refresh()
        let selectionDuringSend = store.selectedAgentID
        gate.release()
        await sending.value
        try expect(journalWasWritten, "The network request started before the recovery journal was saved")
        try expect(selectionDuringSend == "a", "Background overview switched agents while a send was active")
        try expect(journalEntries().isEmpty, "Acknowledged send left the original agent journal unresolved")
    }

    static func recoverUncertainSubmission() async throws {
        seed("recovery")
        let store = WorkspaceStore()
        await store.refresh()
        store.draft = "Keep the original request"
        store.saveDraft()
        network.executeHandler = { _, _ in throw URLError(.timedOut) }
        await store.send()
        let original = try required(store.submission, "Send lost its uncertain recovery state")
        try expect(original.phase == "uncertain", "Interrupted request must become uncertain")
        try expect(journalEntries().count == 1, "Interrupted request journal was not retained")
        let restarted = WorkspaceStore()
        await restarted.refresh()
        try expect(restarted.submission?.call == original.call, "Recreated store did not restore the exact pending request")
        try expect(!restarted.canSubmit, "A pending recovery must block a fresh send")
        network.executeHandler = { _, call in receipt(call) }
        await restarted.send(retry: true)
        try expect(network.calls.count == 2 && network.calls[0] == network.calls[1], "Retry changed the request ID or payload")
        try expect(restarted.submission == nil && journalEntries().isEmpty, "Acknowledged retry did not resolve its journal")
        try expect(restarted.turns.contains { $0.string("turn_id") == original.turnId }, "A stale post-send cache read erased the accepted turn")
        network.workspaces["a"]?.submission = original
        await restarted.refresh()
        try expect(restarted.submission == nil && journalEntries().isEmpty, "A delayed server submission resurrected an already resolved request")
    }

    static func newerRemoteSubmission() -> WorkspaceSubmission {
        WorkspaceSubmission(call: PendingCall(method: .conversationSend, params: ["text": .string("Sent from another device"), "conversation_id": .string("remote-conversation")]), text: "Sent from another device", conversationId: "remote-conversation", turnId: "remote-turn", phase: "uncertain", retryable: true)
    }

    static func reconcileBeforeRemoteSubmission() async throws {
        seed("multiple-devices-accepted")
        let store = WorkspaceStore()
        await store.refresh()
        store.draft = "Local message with a lost receipt"
        store.saveDraft()
        network.executeHandler = { _, _ in throw URLError(.timedOut) }
        await store.send()
        let original = try required(store.submission, "Missing local pending request")
        let remote = newerRemoteSubmission()
        network.workspaces["a"]?.submission = remote
        network.workspaces["a"]?.conversation?["turns"] = .array([.object(turn(original.turnId, time: 10, status: "completed"))])
        await store.refresh()
        try expect(store.draft.isEmpty, "Confirmed local text remained in the draft after adopting another device's request")
        try expect(store.submission?.call == remote.call, "New remote submission was not restored after the local request resolved")
        let persisted = try journalEntries().map { try JSONDecoder().decode(WorkspaceSubmission.self, from: $0) }
        try expect(persisted.count == 1 && persisted.first?.call == remote.call, "Journal did not advance from the confirmed local request to the remote request")
    }

    static func preserveUnverifiedLocalSubmission() async throws {
        seed("multiple-devices-unverified")
        let store = WorkspaceStore()
        await store.refresh()
        store.draft = "Local message without acceptance proof"
        store.saveDraft()
        network.executeHandler = { _, _ in throw URLError(.timedOut) }
        await store.send()
        let original = try required(store.submission, "Missing local pending request")
        network.workspaces["a"]?.submission = newerRemoteSubmission()
        await store.refresh()
        try expect(store.submission?.call == original.call, "Unrelated server submission replaced the unverified local request")
        try expect(store.draft == original.text && store.conversationID == original.conversationId, "Unverified local context was discarded")
        let persisted = try journalEntries().map { try JSONDecoder().decode(WorkspaceSubmission.self, from: $0) }
        try expect(persisted.count == 1 && persisted.first?.call == original.call, "Unverified local recovery journal was overwritten")
        let restarted = WorkspaceStore()
        await restarted.refresh()
        try expect(restarted.submission?.call == original.call, "Recreated store lost the original local recovery request")
    }

    static func unreadableRecoveryJournal() async throws {
        seed("locked-journal")
        let original = WorkspaceStore()
        await original.refresh()
        original.draft = "Pending before journal lock"
        network.executeHandler = { _, _ in throw URLError(.timedOut) }
        await original.send()
        let saved = try required(original.submission, "Missing setup pending request")
        SecureStore.failReads = true
        let restarted = WorkspaceStore()
        await restarted.refresh()
        restarted.draft = "Must not replace unread recovery"
        restarted.saveDraft()
        await restarted.send()
        try expect(!restarted.canSubmit && restarted.error != nil, "Unreadable recovery did not disable new sends with an explanation")
        try expect(network.calls.count == 1, "A new request was sent before the previous recovery could be read")
        SecureStore.failReads = false
        await restarted.refresh()
        try expect(restarted.submission?.call == saved.call, "Refreshing after journal recovery did not restore the original request")
    }

    static func preserveNewConversation() async throws {
        seed("new-conversation", ids: ["a", "b"])
        network.workspaces["a"]?.activeConversationId = ""
        network.workspaces["a"]?.conversation = nil
        let store = WorkspaceStore()
        await store.refresh()
        store.draft = "First message"
        network.executeHandler = { _, call in receipt(call) }
        await store.send()
        let acceptedID = store.conversationID
        try expect(store.turns.count == 1, "Empty workspace cache erased the newly accepted turn")
        await store.refresh()
        try expect(store.turns.count == 1, "Polling erased the newly accepted turn")
        await store.selectAgent("b")
        await store.selectAgent("a")
        try expect(store.conversationID == acceptedID && store.turns.count == 1, "Agent cache did not retain the accepted conversation")
    }

    static func openRemoteConversation() async throws {
        seed("remote-conversation")
        let store = WorkspaceStore()
        await store.refresh()
        var readRemote = false
        network.executeHandler = { _, call in
            try expect(call.method == .conversationGet, "Opening a remote conversation used the wrong method")
            readRemote = true
            return ["conversation_id": .string("remote-only"), "turns": .array([.object(turn("remote-turn", time: 5, status: "completed"))])]
        }
        network.selectHandler = { id, selected in
            try expect(readRemote, "Unknown conversation selected before it had been saved")
            var data = network.workspaces[id]!
            data.activeConversationId = selected ?? ""
            data.conversation = nil
            return data
        }
        await store.openConversation("remote-only")
        try expect(store.error == nil, "Remote conversation failed to open")
        try expect(store.conversationID == "remote-only" && store.turns.first?.string("turn_id") == "remote-turn", "Fetched conversation was not retained after selection")
    }

    static func preserveActionErrors() async throws {
        seed("error-lifetime")
        let store = WorkspaceStore()
        await store.refresh()
        store.error = "An action requires your attention"
        network.fetchHandler = { _, _, _ in throw URLError(.notConnectedToInternet) }
        await store.refresh()
        try expect(store.connectionError != nil, "Read failure did not report its connection problem")
        try expect(store.error == "An action requires your attention", "Polling replaced an action failure with a connection failure")
        network.fetchHandler = nil
        await store.refresh()
        try expect(store.connectionError == nil, "Successful refresh did not clear the connection failure")
        try expect(store.error == "An action requires your attention", "Successful polling erased the action message")
    }

    static func sameAccountRelogin() async throws {
        seed("same-account")
        let store = WorkspaceStore()
        await store.refresh()
        store.draft = "Old login's message"
        let gate = Gate()
        network.executeHandler = { _, call in await gate.wait(); return receipt(call) }
        let sending = Task { await store.send() }
        try await gate.waitUntilEntered()
        network.sessionRevision += 2
        let requestCount = network.requests.count
        gate.release()
        await sending.value
        try expect(network.requests.count == requestCount, "Old operation resumed requests after the same user logged in again")
        try expect(!store.canSend, "Invalidated store still enables sending")
    }

    static func preservePaginatedTranscript() async throws {
        seed("pagination")
        network.workspaces["a"]?.conversation?["turns"] = .array([.object(turn("t3", time: 3, status: "completed"))])
        network.workspaces["a"]?.hasEarlierTurns = true
        let store = WorkspaceStore()
        await store.refresh()
        network.fetchHandler = { id, _, before in
            var result = network.workspaces[id]!
            if before != nil {
                result.conversation?["turns"] = .array([.object(turn("t1", time: 1, status: "completed")), .object(turn("t2", time: 2, status: "running"))])
                result.hasEarlierTurns = false
            } else {
                result.conversation?["turns"] = .array([.object(turn("t3", time: 3, status: "submitted"))])
            }
            return result
        }
        await store.loadEarlier()
        await store.refresh()
        try expect(store.turns.map { $0.string("turn_id") } == ["t1", "t2", "t3"], "Polling discarded or reordered previously loaded turns")
        try expect(store.turns.last?.string("status") == "completed", "Stale cache downgraded a terminal turn")
        try expect(!store.hasEarlierTurns, "Polling reset the exhausted pagination cursor")
    }

    static func accountChangesDuringSend() async throws {
        seed("previous-account")
        let store = WorkspaceStore()
        await store.refresh()
        store.draft = "Belongs to the previous account"
        let gate = Gate()
        network.executeHandler = { _, call in await gate.wait(); return receipt(call) }
        let sending = Task { await store.send() }
        try await gate.waitUntilEntered()
        network.currentUser = SessionUser(id: "new-account", email: "new@example.com")
        gate.release()
        await sending.value
        store.draft = "Late previous account draft"
        store.saveDraft()
        try expect(!network.requests.contains { $0.account == "new-account" }, "Old store issued a follow-up using the newly logged-in account")
        let newHash = SHA256.hash(data: Data((network.baseUrl + "\u{0}new-account").utf8)).map { String(format: "%02x", $0) }.joined()
        try expect(!SecureStore.memory.keys.contains { $0.contains(newHash) }, "Old store wrote a draft or submission into the new account journal")
    }

    static func required<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw HarnessFailure.message(message) }
        return value
    }
}
