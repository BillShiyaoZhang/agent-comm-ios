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
    var isDeletingAccount = false
    var sessionRevision = 0
    var workspaces: [String: WorkspaceAgent] = [:]
    var conversationStates: [String: [String: WorkspaceConversationState]] = [:]
    var overviewIDs: [String] = []
    var reads: [(agent: String, conversation: String?, before: String?)] = []
    var requests: [(account: String, method: String)] = []
    var calls: [PendingCall] = []
    var policy: RemoteRecord = ["status": .string("legacy"), "paused": .bool(false), "can_use_workbench": .bool(true)]
    var policyHandler: (() async throws -> RemoteRecord)?
    var reserveHandler: ((String, PendingCall, String?) async throws -> WorkspaceOperation)?
    var reservedCalls: [PendingCall] = []
    var operationUpdates: [(String, String)] = []
    var executeHandler: ((String, PendingCall) async throws -> RemoteRecord)?
    var fetchHandler: ((String, String?, String?) async throws -> WorkspaceAgent)?
    var selectHandler: ((String, String?) async throws -> WorkspaceAgent)?
    var conversationUpdateHandler: ((String, String?, RemoteRecord) async throws -> RemoteRecord)?

    func reset(_ account: String) {
        sessionRevision += 1
        currentUser = SessionUser(id: account, email: account + "@example.com")
        isAuthenticated = true
        isDeletingAccount = false
        workspaces = [:]; overviewIDs = []; reads = []; requests = []; calls = []
        conversationStates = [:]
        executeHandler = nil; fetchHandler = nil; selectHandler = nil
        conversationUpdateHandler = nil
        policy = ["status": .string("legacy"), "paused": .bool(false), "can_use_workbench": .bool(true)]
        policyHandler = nil; reserveHandler = nil; reservedCalls = []; operationUpdates = []
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
        let savedID = result.activeConversationId
        if let state = result.activeConversationState { conversationStates[agentId, default: [:]][savedID] = state }
        if let conversationId {
            result.activeConversationId = conversationId
            if result.conversation?.string("conversation_id") != conversationId { result.conversation = nil }
        }
        result.activeConversationState = conversationStates[agentId]?[result.activeConversationId] ?? .init()
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
        if let data = workspaces[agentId], let state = data.activeConversationState { conversationStates[agentId, default: [:]][data.activeConversationId] = state }
        workspaces[agentId]?.activeConversationId = conversationId ?? ""
        workspaces[agentId]?.activeConversationState = conversationStates[agentId]?[conversationId ?? ""] ?? .init()
        return try await fetchWorkspace(agentId: agentId, conversationId: conversationId ?? "")
    }
    func dismissSubmission(agentId: String, requestId: String) async throws -> WorkspaceAgent {
        workspaces[agentId]?.submission = nil
        return try await fetchWorkspace(agentId: agentId)
    }
    func fetchPolicy() async throws -> RemoteRecord {
        record("policy")
        if let policyHandler { return try await policyHandler() }
        return policy
    }
    func updatePolicy(_ body: RemoteRecord) async throws -> RemoteRecord {
        record("policy-update")
        policy["paused"] = .bool(false); policy["can_use_workbench"] = .bool(true)
        return policy
    }
    func pausePolicy() async throws { record("policy-pause"); policy["paused"] = .bool(true); policy["can_use_workbench"] = .bool(false) }
    func fetchOperations(agentId: String) async throws -> [WorkspaceOperation] {
        record("operations")
        return workspaces[agentId]?.operations ?? []
    }
    func reserveOperation(agentId: String, call: PendingCall, conversationId: String? = nil) async throws -> WorkspaceOperation {
        record("reserve"); reservedCalls.append(call)
        if let reserveHandler { return try await reserveHandler(agentId, call, conversationId) }
        if let original = workspaces[agentId]?.operations?.first(where: { $0.call == call }) { return original }
        let item = WorkspaceOperation(call: call, conversationId: conversationId, createdAt: Date().timeIntervalSince1970 * 1000, updatedAt: Date().timeIntervalSince1970 * 1000)
        var items = workspaces[agentId]?.operations ?? []
        if !items.contains(where: { $0.call.requestId == call.requestId }) { items.append(item) }
        workspaces[agentId]?.operations = items
        return item
    }
    func updateOperation(agentId: String, requestId: String, phase: String, message: String, retryable: Bool) async throws -> WorkspaceOperation {
        record("operation-update"); operationUpdates.append((requestId, phase))
        guard var item = workspaces[agentId]?.operations?.first(where: { $0.call.requestId == requestId }) else { throw HarnessFailure.message("Missing reserved operation") }
        if !item.unresolved { return item }
        item.phase = "uncertain"; item.message = message; item.retryable = retryable; item.updatedAt = Date().timeIntervalSince1970 * 1000
        workspaces[agentId]?.operations?.removeAll(where: { $0.call.requestId == requestId })
        workspaces[agentId]?.operations?.append(item)
        return item
    }
    func fetchNotifications(filter: String = "all", before: Double? = nil) async throws -> RemoteRecord {
        record("notifications")
        return ["items": .array([]), "unread": .number(0), "pending": .number(0), "before": .null, "hasMore": .bool(false)]
    }
    func markNotificationRead(agentId: String, id: String, revision: Int) async throws { record("notification-read") }
    func fetchConversations(agentId: String, query: String = "", archived: String = "active", deleted: String = "active", before: String? = nil) async throws -> RemoteRecord {
        record("conversations")
        let data = try JSONEncoder().encode(workspaces[agentId]?.conversations ?? [])
        let items = try JSONDecoder().decode(JSONValue.self, from: data)
        return ["items": items, "before": .null, "hasMore": .bool(false), "scope": .string("saved_account_history")]
    }
    func updateConversation(agentId: String, conversationId: String?, patch: RemoteRecord) async throws -> RemoteRecord {
        record("conversation-update")
        if let conversationUpdateHandler { return try await conversationUpdateHandler(agentId, conversationId, patch) }
        if let text = patch["draft"]?.stringValue {
            let id = conversationId ?? ""
            var state = conversationStates[agentId]?[id] ?? .init()
            state.draft = text
            conversationStates[agentId, default: [:]][id] = state
            if workspaces[agentId]?.activeConversationId == id { workspaces[agentId]?.activeConversationState = state }
        }
        return ["state": .object(patch)]
    }
    func renameConnection(agentId: String, name: String) async throws { record("rename"); workspaces[agentId]?.agent.name = name }
    func removeConnection(agentId: String) async throws { record("remove"); overviewIDs.removeAll(where: { $0 == agentId }); workspaces[agentId] = nil }
    func saveRecordState(agentId: String, kind: String, id: String, deleted: Bool) async throws -> WorkspaceRecordState {
        record("record-update")
        let value = WorkspaceRecordState(kind: kind, id: id, deleted: deleted)
        workspaces[agentId]?.recordStates = [value]
        return value
    }
    func fetchActivity() async throws -> RemoteRecord { record("activity"); return [:] }
    func fetchAccount() async throws -> RemoteRecord { record("account"); return ["email": .string(currentUser?.email ?? ""), "verified": .bool(true)] }
    func previewOnboarding(code: String) async throws -> RemoteRecord { record("onboarding-preview"); return ["status": .string("pending")] }
    func approveOnboarding(code: String) async throws -> RemoteRecord { record("onboarding-approve"); return ["status": .string("approved"), "agent_id": .string("a")] }
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
        await test("paused policy retains saved history and blocks remote reads and writes", pausedPolicyRetainsHistory)
        await test("unavailable policy retains saved history and blocks remote reads and writes", unavailablePolicyRetainsHistory)
        await test("collaboration description is a read and does not reserve a mutation", descriptionIsReadOnly)
        await test("mutations reserve their exact request before remote delivery", reserveBeforeMutation)
        await test("reservation failure prevents remote mutation delivery", reservationFailureBlocksMutation)
        await test("restored unresolved operations block a second write to the same subject", restoredMutationBlocksDuplicate)
        await test("authenticated uncertain execution remains unresolved and is never replayed", authenticatedUncertainMutation)
        await test("uncertain transport errors preserve the original mutation for explicit retry", transportUncertainMutation)
        await test("changed approval questions or subjects prevent an obsolete decision", changedApprovalPreventsWrite)
        await test("an unchanged approval is re-read before its exact decision is submitted", unchangedApprovalIsRevalidated)
        await test("account changes after mutation reservation prevent delivery", accountChangesDuringReservation)
        await test("account changes during a mutation stop result updates and follow-up reads", accountChangesDuringMutation)
        await test("hidden record states respect kind and related IDs and can be restored", hiddenRecordFiltering)
        await test("newer combined collaboration data takes precedence over older standalone lists", combinedSnapshotPrecedence)
        await test("conversation and new-chat drafts stay isolated when switching and restarting", conversationDraftIsolation)
        await test("saved account drafts restore without overwriting unsynchronized local text", savedDraftFallback)
        await test("a delayed policy read cannot override a successful explicit resume", delayedPolicyReadAfterResume)
        await test("an unknown collaboration write blocks other actions but permits its exact retry", unresolvedCollaborationBlocksOtherActions)
        await test("confirmed draft saves release local overrides so another device can update them", confirmedDraftReleasesLocalOverride)
        await test("a draft edited during saving survives the older save acknowledgement", editingDuringDraftSave)
        await test("a previous account's draft save acknowledgement cannot clear local recovery", accountChangesDuringDraftSave)
        await test("an account draft for an empty new conversation hydrates before sending", newConversationAccountDraft)
        await test("an unsynchronized cleared draft stays cleared across a failed save and switch", clearedDraftSurvivesSwitch)
        await test("draft saves remain serial after their initiating view task is cancelled", draftSaveQueuePreservesOrder)
        await test("another device's pending send never absorbs this conversation's draft", foreignSubmissionPreservesScopedDraft)
        await test("a remotely deleted active conversation clears its transcript and focus", remotelyDeletedConversation)
        await test("legacy agent-wide drafts migrate into the selected conversation", legacyDraftMigration)
        await test("account deletion pauses remote work and local draft writes", accountDeletionPausesWork)
        await test("a late draft save cannot recreate data after account deletion", accountDeletionStopsLateDraftSave)
        await test("declined sharing blocks content writes before journals or reservations but permits reads", declinedSharingStopsWrites)
        await test("sharing permission lasts only for this selected Agent and login session", sharingScopeLifetime)
        await test("withdrawn sharing blocks exact conversation and action retries", withdrawnSharingStopsRetries)
        await test("withdrawal during reservation prevents dispatch even after a new grant", withdrawalDuringReservation)
        await test("withdrawal after dispatch preserves the real response and blocks the next send", withdrawalAfterDispatch)
        await test("safety controls work without AI sharing and require exact Agent receipts", safetyControlsWithoutSharing)
        await test("unknown block results prevent a contradictory unblock request", unresolvedSafetyBlocksContradictoryWrite)
        await test("old Agent capabilities cannot claim a block and expose independent blocked peers", oldAgentSafetyCapabilities)
        await test("legacy peer model execution cannot accept new private conversation content", legacyPeerModelCannotReceiveNewContent)
        await test("verified block receipts survive stale snapshots and recovery until a newer decision", safetyRevisionSurvivesStaleReadsAndRecovery)
        if failures > 0 { exit(1) }
        print("All workspace store regressions passed.")
    }

    static func accountDeletionPausesWork() async throws {
        seed("delete-pauses")
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
        store.draft = "删除前草稿"
        store.saveDraft()
        let saved = SecureStore.memory
        let requests = network.requests.count
        network.isDeletingAccount = true
        try expect(!store.canSend && !store.canAct(.messagesSend), "Deletion left remote actions available")
        store.draft = "不应保存"
        store.saveDraft()
        await store.syncDraft()
        await store.send()
        await store.refresh(schedule: true)
        try expect(SecureStore.memory == saved, "Draft persisted during account deletion")
        try expect(network.requests.count == requests && network.calls.isEmpty, "Remote work started during deletion")
        network.isDeletingAccount = false
        try expect(store.canSend, "A rejected deletion left the current account permanently paused")
    }

    static func accountDeletionStopsLateDraftSave() async throws {
        seed("delete-late-save")
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
        store.draft = "待保存"
        store.saveDraft()
        let gate = Gate()
        network.conversationUpdateHandler = { _, _, _ in await gate.wait(); return [:] }
        let saving = Task { await store.syncDraft() }
        try await gate.waitUntilEntered()
        network.isDeletingAccount = true
        network.isAuthenticated = false
        network.sessionRevision += 1
        SecureStore.memory = [:]
        gate.release()
        await saving.value
        store.saveDraft()
        try expect(SecureStore.memory.isEmpty, "A late save recreated deleted account recovery data")
    }

    static func test(_ name: String, _ operation: () async throws -> Void) async {
        do { try await operation(); print("PASS: " + name) }
        catch { failures += 1; print("FAIL: " + name + " — " + String(describing: error)) }
    }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw HarnessFailure.message(message) }
    }
    // Existing transport regressions model the user having explicitly authorized sharing.
    // Permission regressions below call refresh directly and exercise each decision themselves.
    static func refreshAllowingSharing(_ store: WorkspaceStore) async {
        await store.refresh()
        if !store.hasAgentSharingPermission, let context = store.sharingContext { store.allowAgentSharing(context) }
    }

    static func declinedSharingStopsWrites() async throws {
        seed("sharing-declined")
        let store = WorkspaceStore()
        await store.refresh()
        store.draft = "Do not share this"
        store.saveDraft()
        let journal = SecureStore.memory
        await store.send()
        for method in [RPCMethod.contactsAdd, .contactsRespond, .messagesSend, .approvalRespond, .collaborationExecute] {
            await store.performAction(method, params: ["action": "dispatch", "text": "Do not share this"])
        }
        try expect(network.calls.isEmpty && network.reservedCalls.isEmpty, "Declined permission sent or reserved content")
        try expect(SecureStore.memory == journal && store.submission == nil, "Declined permission created a submission journal")
        try expect(store.error != nil, "A direct unauthorized send failed without an explanation")
        await store.describeCollaboration()
        try expect(network.calls.last?.params == ["action": "describe"], "Declined sharing blocked read-only inspection")
    }

    static func sharingScopeLifetime() async throws {
        seed("sharing-lifetime", ids: ["a", "b"])
        let store = WorkspaceStore()
        await store.refresh()
        let first = try required(store.sharingContext, "Sharing disclosure has no actual Agent scope")
        try expect(first.server == network.baseUrl && first.accountID == network.currentUser?.id && first.agentURN == "urn:agent:a", "Disclosure is not bound to the actual account, server and URN")
        try expect(store.allowAgentSharing(first) && store.hasAgentSharingPermission, "Explicit consent was not accepted")
        network.executeHandler = { _, call in receipt(call) }
        for text in ["First authorized message", "Second authorized message"] {
            store.draft = text
            await store.send()
        }
        try expect(network.calls.count == 2, "Same-Agent messages required repeated permission")
        let restarted = WorkspaceStore()
        await restarted.refresh()
        try expect(!restarted.hasAgentSharingPermission, "A recreated session restored sharing permission")
        await store.selectAgent("b")
        try expect(!store.hasAgentSharingPermission && !store.allowAgentSharing(first), "Permission crossed into another Agent")
        await store.selectAgent("a")
        try expect(!store.hasAgentSharingPermission, "Returning to an Agent silently restored the previous permission")
        let current = try required(store.sharingContext, "Returning Agent lost disclosure")
        store.allowAgentSharing(current)
        network.sessionRevision += 1
        try expect(!store.hasAgentSharingPermission && !store.allowAgentSharing(current), "Permission survived a new login revision")
    }

    static func withdrawnSharingStopsRetries() async throws {
        seed("sharing-retry")
        let store = WorkspaceStore()
        await store.refresh()
        let context = try required(store.sharingContext, "Missing disclosure")
        store.allowAgentSharing(context)
        store.draft = "Keep this exact request"
        network.executeHandler = { _, _ in throw URLError(.timedOut) }
        await store.send()
        let original = try required(store.submission, "Uncertain send was not retained")
        let journal = SecureStore.memory, sent = network.calls.count
        store.revokeAgentSharing()
        await store.send(retry: true)
        try expect(network.calls.count == sent && store.submission?.call == original.call && SecureStore.memory == journal, "Withdrawn permission changed or replayed a conversation request")
        store.allowAgentSharing(context)
        network.executeHandler = { _, call in receipt(call) }
        await store.send(retry: true)
        try expect(network.calls.count == sent + 1 && network.calls.last == original.call, "New consent did not preserve the exact conversation retry")
        network.executeHandler = { _, _ in throw URLError(.timedOut) }
        await store.performAction(.messagesSend, params: ["message_id": "peer-message-1", "text": "Peer content"])
        let action = try required(store.uncertainActions.first, "Uncertain social action was lost")
        let reserved = network.reservedCalls.count, delivered = network.calls.count
        store.revokeAgentSharing()
        await store.retryAction(action)
        try expect(network.calls.count == delivered && network.reservedCalls.count == reserved, "Withdrawn permission replayed a saved social request")
        store.allowAgentSharing(context)
        await store.retryAction(action)
        try expect(network.calls.count == delivered + 1 && network.calls.last == action.call, "Explicit new consent changed the original social request")
    }

    static func withdrawalDuringReservation() async throws {
        for regrant in [false, true] {
            seed("sharing-reserve-" + String(regrant))
            let store = WorkspaceStore()
            await store.refresh()
            let context = try required(store.sharingContext, "Missing disclosure")
            store.allowAgentSharing(context)
            let gate = Gate()
            network.reserveHandler = { id, call, _ in
                let saved = WorkspaceOperation(call: call)
                network.workspaces[id]?.operations = [saved]
                await gate.wait()
                return saved
            }
            let submitting = Task { await store.performAction(.messagesSend, params: ["message_id": "message-reserved", "text": "Reserved content"]) }
            try await gate.waitUntilEntered()
            store.revokeAgentSharing()
            if regrant { store.allowAgentSharing(context) }
            gate.release()
            await submitting.value
            try expect(network.calls.isEmpty && network.reservedCalls.count == 1, "A withdrawn or replaced grant dispatched after reservation")
            try expect(store.uncertainActions.count == 1 && store.error != nil && store.busy == nil, "Stopped dispatch lost its original reservation or remained busy")
        }
    }

    static func withdrawalAfterDispatch() async throws {
        seed("sharing-after-dispatch")
        let store = WorkspaceStore()
        await store.refresh()
        let context = try required(store.sharingContext, "Missing disclosure")
        store.allowAgentSharing(context)
        store.draft = "Already dispatched"
        let gate = Gate()
        network.executeHandler = { _, call in await gate.wait(); return receipt(call) }
        let sending = Task { await store.send() }
        try await gate.waitUntilEntered()
        store.revokeAgentSharing()
        gate.release()
        await sending.value
        try expect(store.submission == nil && journalEntries().isEmpty, "Withdrawal misreported an authenticated dispatched result as failure")
        store.draft = "Future content"
        await store.send()
        try expect(network.calls.count == 1, "Withdrawal permitted a new content send")
    }
    static func safetyControlsWithoutSharing() async throws {
        seed("safety-controls")
        let store = WorkspaceStore()
        await store.refresh()
        try expect(!store.hasAgentSharingPermission, "Safety regression unexpectedly consented to AI sharing")
        network.executeHandler = { _, call in
            switch call.method {
            case .contactsBlock: return ["urn": call.params["urn"]!, "status": "blocked", "blocked": true, "connection_status": "blocked", "safety_revision": 1]
            case .contactsUnblock: return ["urn": call.params["urn"]!, "status": "unblocked", "blocked": false, "connection_status": "connected", "safety_revision": 2]
            default: return ["message_id": call.params["message_id"]!, "status": "approved"]
            }
        }
        await store.performAction(.contactsBlock, params: ["urn": "urn:agent:peer-one"])
        try expect(network.calls.count == 1 && network.operationUpdates.last?.1 == "succeeded", "Lack of AI permission blocked an actual safety control")
        await store.performAction(.inboxReview, params: ["message_id": "message-one", "decision": "approve"])
        try expect(network.calls.count == 2 && network.operationUpdates.last?.1 == "succeeded", "Owner-only content review required unrelated AI sharing")

        seed("safety-mismatched-receipt")
        let second = WorkspaceStore(); await second.refresh()
        network.executeHandler = { _, _ in ["urn": "urn:agent:someone-else", "status": "blocked", "blocked": true, "connection_status": "blocked"] }
        await second.performAction(.contactsBlock, params: ["urn": "urn:agent:peer-two"])
        try expect(network.operationUpdates.last?.1 == "uncertain", "A different URN was accepted as blocked")
        try expect(!second.peerIsBlocked("urn:agent:peer-two"), "An uncertain response invented a persisted block")
    }
    static func unresolvedSafetyBlocksContradictoryWrite() async throws {
        seed("safety-uncertain")
        let original = PendingCall(method: .contactsBlock, params: ["urn": "urn:agent:peer"])
        network.workspaces["a"]?.operations = [WorkspaceOperation(call: original, phase: "uncertain")]
        let store = WorkspaceStore(); await store.refresh()
        await store.performAction(.contactsUnblock, params: ["urn": "urn:agent:peer"])
        try expect(network.calls.isEmpty && network.reservedCalls.isEmpty, "An unknown block allowed a contradictory new unblock")
        try expect(store.peerSafetyPending("urn:agent:peer") && store.error != nil, "Unresolved safety state was hidden")
    }
    static func oldAgentSafetyCapabilities() async throws {
        seed("safety-old-agent")
        network.workspaces["a"]?.contentSafety = nil
        network.workspaces["a"]?.snapshots["capabilities"]?.data = ["methods": [["name": "contacts.list", "available": true]]]
        network.workspaces["a"]?.snapshots["contacts.list"] = WorkspaceSnapshot(data: ["contacts": [], "blocked_peers": [["urn": "urn:agent:request-only", "blocked": true, "connection_status": "blocked"]]], time: 200)
        let store = WorkspaceStore(); await store.refresh()
        await store.performAction(.contactsBlock, params: ["urn": "urn:agent:peer"])
        try expect(network.calls.isEmpty && network.reservedCalls.isEmpty, "An old Agent silently accepted a safety operation")
        try expect(store.peerIsBlocked("urn:agent:request-only") && store.blockedPeers.count == 1, "A blocked non-contact sender could not be managed")
        try expect(!store.contentSafetyAvailable, "A legacy Web inferred content review capability from Agent metadata")
    }

    static func legacyPeerModelCannotReceiveNewContent() async throws {
        let unsafe: [JSONValue?] = [nil, ["version": 1, "mode": "owner_review"], ["version": 1, "mode": "owner_review", "automatic_peer_model_execution": true], ["version": 1, "mode": "legacy", "automatic_peer_model_execution": false]]
        for (index, value) in unsafe.enumerated() {
            seed("legacy-peer-model-\(index)")
            network.workspaces["a"]?.snapshots["capabilities"]?.data["peer_content_safety"] = value
            let store = WorkspaceStore(); await refreshAllowingSharing(store)
            store.draft = "New private content"
            await store.send()
            await store.performAction(.messagesSend, params: ["recipient_urn": "urn:agent:peer", "text": "New peer content"])
            try expect(!store.canSend && !store.canAct(.messagesSend), "An incomplete or automatic peer runtime claimed the safe input capability")
            try expect(network.calls.isEmpty && network.reservedCalls.isEmpty && journalEntries().isEmpty, "Legacy peer content reached a new model turn before review capability was verified")
            try expect(network.reads.count > 0 && store.canAct(.contactsBlock), "An upgrade requirement removed saved history or safety controls")
        }
    }

    static func safetyRevisionSurvivesStaleReadsAndRecovery() async throws {
        seed("safety-monotonic")
        let urn = "urn:agent:request-sender"
        network.workspaces["a"]?.snapshots["contacts.list"] = WorkspaceSnapshot(data: ["safety_revision": 0, "contacts": [], "blocked_peers": []], time: 300)
        let store = WorkspaceStore(); await store.refresh()
        network.executeHandler = { _, _ in ["urn": .string(urn), "status": "blocked", "blocked": true, "connection_status": "blocked", "safety_revision": 1] }
        await store.performAction(.contactsBlock, params: ["urn": .string(urn)])
        try expect(store.peerIsBlocked(urn) && store.blockedPeers.contains { $0.string("urn") == urn }, "A late snapshot erased the actual block receipt")
        let call = network.calls[0]
        network.workspaces["a"]?.operations = [WorkspaceOperation(call: call, phase: "succeeded", result: ["urn": .string(urn), "status": "blocked", "blocked": true, "connection_status": "blocked", "safety_revision": 1])]
        let recovered = WorkspaceStore(); await recovered.refresh()
        try expect(recovered.peerIsBlocked(urn) && recovered.blockedPeers.contains { $0.string("urn") == urn }, "A contactless blocked peer disappeared after recovering its verified operation")
        network.workspaces["a"]?.snapshots["collaboration.state"] = WorkspaceSnapshot(data: ["safety_revision": 2, "contacts": [], "blocked_peers": []], time: 100)
        await recovered.refresh()
        try expect(!recovered.peerIsBlocked(urn) && recovered.blockedPeers.isEmpty, "A recovered old block overrode a newer real unblock with an earlier receipt clock")
    }

    static func fixture(_ id: String, conversation: String? = nil) -> WorkspaceAgent {
        let conversation = conversation ?? "conversation-" + id
        return WorkspaceAgent(
            agent: WorkspaceConnection(id: id, name: id, urn: "urn:agent:" + id),
            identity: WorkspaceIdentity(virtualUrn: "urn:virtual:test"),
            sync: WorkspaceSync(status: "ready"),
            snapshots: ["capabilities": WorkspaceSnapshot(data: ["methods": .array(RPCMethod.allCases.map { .object(["name": .string($0.rawValue), "available": .bool(true)]) }), "peer_content_safety": ["version": 1, "mode": "owner_review", "automatic_peer_model_execution": false]], time: 100)],
            activeConversationId: conversation,
            conversation: ["conversation_id": .string(conversation), "turns": .array([])], contentSafety: ["version": 1]
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
        await refreshAllowingSharing(store)
        await store.selectAgent("b")
        try expect(store.conversationID == "conversation-b", "Uncached agent incorrectly opens a new conversation")
        try expect(network.reads.last?.conversation == nil, "Initial agent read must omit conversation_id")
    }

    static func agentRemovalDuringSend() async throws {
        seed("agent-removal", ids: ["a", "b"])
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
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
        await refreshAllowingSharing(store)
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
        await refreshAllowingSharing(store)
        store.draft = "Keep the original request"
        store.saveDraft()
        network.executeHandler = { _, _ in throw URLError(.timedOut) }
        await store.send()
        let original = try required(store.submission, "Send lost its uncertain recovery state")
        try expect(original.phase == "uncertain", "Interrupted request must become uncertain")
        try expect(journalEntries().count == 1, "Interrupted request journal was not retained")
        let restarted = WorkspaceStore()
        await refreshAllowingSharing(restarted)
        try expect(restarted.submission?.call == original.call, "Recreated store did not restore the exact pending request")
        try expect(!restarted.canSubmit, "A pending recovery must block a fresh send")
        network.executeHandler = { _, call in receipt(call) }
        await restarted.send(retry: true)
        try expect(network.calls.count == 2 && network.calls[0] == network.calls[1], "Retry changed the request ID or payload")
        try expect(restarted.submission == nil && journalEntries().isEmpty, "Acknowledged retry did not resolve its journal")
        try expect(restarted.turns.contains { $0.string("turn_id") == original.turnId }, "A stale post-send cache read erased the accepted turn")
        network.workspaces["a"]?.submission = original
        await refreshAllowingSharing(restarted)
        try expect(restarted.submission == nil && journalEntries().isEmpty, "A delayed server submission resurrected an already resolved request")
    }

    static func newerRemoteSubmission() -> WorkspaceSubmission {
        WorkspaceSubmission(call: PendingCall(method: .conversationSend, params: ["text": .string("Sent from another device"), "conversation_id": .string("remote-conversation")]), text: "Sent from another device", conversationId: "remote-conversation", turnId: "remote-turn", phase: "uncertain", retryable: true)
    }

    static func reconcileBeforeRemoteSubmission() async throws {
        seed("multiple-devices-accepted")
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
        store.draft = "Local message with a lost receipt"
        store.saveDraft()
        network.executeHandler = { _, _ in throw URLError(.timedOut) }
        await store.send()
        let original = try required(store.submission, "Missing local pending request")
        let remote = newerRemoteSubmission()
        network.workspaces["a"]?.submission = remote
        network.workspaces["a"]?.conversation?["turns"] = .array([.object(turn(original.turnId, time: 10, status: "completed"))])
        await refreshAllowingSharing(store)
        try expect(store.draft.isEmpty, "Confirmed local text remained in the draft after adopting another device's request")
        try expect(store.submission?.call == remote.call, "New remote submission was not restored after the local request resolved")
        let persisted = try journalEntries().map { try JSONDecoder().decode(WorkspaceSubmission.self, from: $0) }
        try expect(persisted.count == 1 && persisted.first?.call == remote.call, "Journal did not advance from the confirmed local request to the remote request")
    }

    static func preserveUnverifiedLocalSubmission() async throws {
        seed("multiple-devices-unverified")
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
        store.draft = "Local message without acceptance proof"
        store.saveDraft()
        network.executeHandler = { _, _ in throw URLError(.timedOut) }
        await store.send()
        let original = try required(store.submission, "Missing local pending request")
        network.workspaces["a"]?.submission = newerRemoteSubmission()
        await refreshAllowingSharing(store)
        try expect(store.submission?.call == original.call, "Unrelated server submission replaced the unverified local request")
        try expect(store.draft == original.text && store.conversationID == original.conversationId, "Unverified local context was discarded")
        let persisted = try journalEntries().map { try JSONDecoder().decode(WorkspaceSubmission.self, from: $0) }
        try expect(persisted.count == 1 && persisted.first?.call == original.call, "Unverified local recovery journal was overwritten")
        let restarted = WorkspaceStore()
        await refreshAllowingSharing(restarted)
        try expect(restarted.submission?.call == original.call, "Recreated store lost the original local recovery request")
    }

    static func unreadableRecoveryJournal() async throws {
        seed("locked-journal")
        let original = WorkspaceStore()
        await refreshAllowingSharing(original)
        original.draft = "Pending before journal lock"
        network.executeHandler = { _, _ in throw URLError(.timedOut) }
        await original.send()
        let saved = try required(original.submission, "Missing setup pending request")
        SecureStore.failReads = true
        let restarted = WorkspaceStore()
        await refreshAllowingSharing(restarted)
        restarted.draft = "Must not replace unread recovery"
        restarted.saveDraft()
        await restarted.send()
        try expect(!restarted.canSubmit && restarted.error != nil, "Unreadable recovery did not disable new sends with an explanation")
        try expect(network.calls.count == 1, "A new request was sent before the previous recovery could be read")
        SecureStore.failReads = false
        await refreshAllowingSharing(restarted)
        try expect(restarted.submission?.call == saved.call, "Refreshing after journal recovery did not restore the original request")
    }

    static func preserveNewConversation() async throws {
        seed("new-conversation", ids: ["a", "b"])
        network.workspaces["a"]?.activeConversationId = ""
        network.workspaces["a"]?.conversation = nil
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
        store.draft = "First message"
        network.executeHandler = { _, call in receipt(call) }
        await store.send()
        let acceptedID = store.conversationID
        try expect(store.turns.count == 1, "Empty workspace cache erased the newly accepted turn")
        await refreshAllowingSharing(store)
        try expect(store.turns.count == 1, "Polling erased the newly accepted turn")
        await store.selectAgent("b")
        await store.selectAgent("a")
        try expect(store.conversationID == acceptedID && store.turns.count == 1, "Agent cache did not retain the accepted conversation")
    }

    static func openRemoteConversation() async throws {
        seed("remote-conversation")
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
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
        await refreshAllowingSharing(store)
        store.error = "An action requires your attention"
        network.fetchHandler = { _, _, _ in throw URLError(.notConnectedToInternet) }
        await refreshAllowingSharing(store)
        try expect(store.connectionError != nil, "Read failure did not report its connection problem")
        try expect(store.error == "An action requires your attention", "Polling replaced an action failure with a connection failure")
        network.fetchHandler = nil
        await refreshAllowingSharing(store)
        try expect(store.connectionError == nil, "Successful refresh did not clear the connection failure")
        try expect(store.error == "An action requires your attention", "Successful polling erased the action message")
    }

    static func sameAccountRelogin() async throws {
        seed("same-account")
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
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
        await refreshAllowingSharing(store)
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
        await refreshAllowingSharing(store)
        try expect(store.turns.map { $0.string("turn_id") } == ["t1", "t2", "t3"], "Polling discarded or reordered previously loaded turns")
        try expect(store.turns.last?.string("status") == "completed", "Stale cache downgraded a terminal turn")
        try expect(!store.hasEarlierTurns, "Polling reset the exhausted pagination cursor")
    }

    static func accountChangesDuringSend() async throws {
        seed("previous-account")
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
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

    static func savedHistoryFixture() {
        network.workspaces["a"]?.conversation?["turns"] = .array([.object(turn("saved-terminal-turn", time: 10, status: "completed"))])
    }

    static func verifyPolicyBlocksControl(_ store: WorkspaceStore) async throws {
        store.draft = "Must remain a draft"
        await store.refresh(schedule: true)
        await store.send()
        await store.invoke(.capabilities)
        await store.invoke(.conversationGet, params: ["conversation_id": .string("conversation-a")])
        await store.openConversation("unknown-remote-conversation")
        await store.describeCollaboration()
        await store.performAction(.inboxMarkRead, params: ["message_id": .string("message-protected")])
        try expect(!store.canSend && !store.canAct(.inboxMarkRead), "Policy denial still authorizes remote actions")
        try expect(network.calls.isEmpty && network.reservedCalls.isEmpty, "A control request was delivered while policy access was blocked")
        try expect(!network.requests.contains(where: { $0.method == "sync" }), "Policy denial scheduled remote synchronization")
        try expect(store.turns.first?.string("turn_id") == "saved-terminal-turn", "Policy denial discarded saved account history")
        try expect(store.draft == "Must remain a draft", "Blocked sending erased the user's draft")
    }

    static func pausedPolicyRetainsHistory() async throws {
        seed("paused-policy")
        savedHistoryFixture()
        network.policy = ["status": .string("signed"), "mode": .string("compliance"), "paused": .bool(true), "confirmed": .bool(true), "can_use_workbench": .bool(false)]
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
        try await verifyPolicyBlocksControl(store)
    }

    static func unavailablePolicyRetainsHistory() async throws {
        seed("unavailable-policy")
        savedHistoryFixture()
        network.policyHandler = { throw WorkspaceClientError.serverError(503) }
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
        try await verifyPolicyBlocksControl(store)
        try expect(store.policyError != nil, "Policy verification failure has no explanation")
    }

    static func descriptionIsReadOnly() async throws {
        seed("description")
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
        network.executeHandler = { _, call in
            try expect(call.method == .collaborationExecute && call.params == ["action": .string("describe")], "Description read sent an unexpected request")
            return ["actions": .array([.string("prepare_task")])]
        }
        await store.describeCollaboration()
        try expect(network.calls.count == 1 && network.reservedCalls.isEmpty, "Read-only description was added to the mutation ledger")
        try expect(store.collaborationDescription.strings("actions") == ["prepare_task"], "Agent description was not retained")
    }

    static func reserveBeforeMutation() async throws {
        seed("reserve-before-send")
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
        let params: RemoteRecord = ["request_id": .string("friend-request-1"), "decision": .string("accept")]
        network.executeHandler = { id, call in
            try expect(network.reservedCalls.last == call, "Remote delivery did not match the durably reserved call")
            try expect(network.workspaces[id]?.operations?.contains(where: { $0.call == call }) == true, "Remote delivery started before durable reservation")
            return ["request_id": .string("friend-request-1"), "status": .string("accepted")]
        }
        await store.performAction(.contactsRespond, params: params)
        try expect(network.calls.count == 1 && network.reservedCalls.count == 1, "Explicit mutation was not delivered exactly once")
        try expect(network.calls.first?.params == params, "Reservation changed the original parameters")
        let sequence = network.requests.map(\.method)
        try expect(sequence.firstIndex(of: "reserve")! < sequence.firstIndex(of: "execute")!, "Operation reservation did not precede delivery")
    }

    static func reservationFailureBlocksMutation() async throws {
        seed("reservation-failure")
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
        network.reserveHandler = { _, _, _ in throw WorkspaceClientError.serverError(503) }
        await store.performAction(.inboxMarkRead, params: ["message_id": .string("message-1")])
        try expect(network.reservedCalls.count == 1 && network.calls.isEmpty, "Failed reservation still delivered a write")
        try expect(store.error != nil || store.actionResult != nil, "Failed reservation has no actionable explanation")
    }

    static func restoredMutationBlocksDuplicate() async throws {
        seed("restored-operation")
        let original = PendingCall(method: .inboxMarkRead, params: ["message_id": .string("message-1")])
        network.workspaces["a"]?.operations = [WorkspaceOperation(call: original, phase: "uncertain", retryable: true)]
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
        try expect(store.uncertainActions.first?.call == original, "Stored operation did not restore its exact identity")
        await store.performAction(.inboxMarkRead, params: original.params)
        try expect(network.calls.isEmpty && network.reservedCalls.isEmpty, "Restoration silently generated a second request for the same subject")
        await refreshAllowingSharing(store)
        try expect(network.calls.isEmpty, "Polling automatically replayed a restored operation")
    }

    static func authenticatedUncertainMutation() async throws {
        seed("authenticated-uncertainty")
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
        network.executeHandler = { id, call in
            let result: RemoteRecord = ["status": .string("uncertain"), "instruction": .string("Reconcile the original operation")]
            if let index = network.workspaces[id]?.operations?.firstIndex(where: { $0.call == call }) {
                network.workspaces[id]?.operations?[index].phase = "uncertain"
                network.workspaces[id]?.operations?[index].retryable = false
                network.workspaces[id]?.operations?[index].result = result
            }
            return result
        }
        await store.performAction(.collaborationExecute, params: ["action": .string("dispatch"), "operation_id": .string("operation-1")])
        let original = try required(store.uncertainActions.first, "Authenticated uncertainty was reported as a successful write")
        try expect(original.phase == "uncertain" && !original.retryable, "Ambiguous authenticated effect was made safely retryable")
        await refreshAllowingSharing(store)
        await store.performAction(.collaborationExecute, params: original.call.params)
        try expect(network.calls.count == 1, "Uncertain business effect was automatically duplicated")
        try expect(store.uncertainActions.first?.call == original.call, "Uncertain effect lost its original request identity")
    }

    static func transportUncertainMutation() async throws {
        seed("transport-uncertainty")
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
        network.executeHandler = { _, call in throw ControlCallError("A receipt has not arrived", call: call, retryable: true, uncertain: true) }
        await store.performAction(.inboxMarkRead, params: ["message_id": .string("message-1")])
        let original = try required(store.uncertainActions.first, "Uncertain transport failure discarded the original mutation")
        try expect(original.phase == "uncertain" && original.retryable, "Uncertain transport was presented as a final rejection")
        await refreshAllowingSharing(store)
        try expect(network.calls.count == 1, "Refresh automatically retried a write")
        network.executeHandler = { _, _ in ["message_id": .string("message-1"), "status": .string("read")] }
        await store.retryAction(original)
        try expect(network.calls.count == 2 && network.calls[0] == network.calls[1], "Explicit retry changed the original request ID or parameters")
    }

    static func approvalFixture() -> RemoteRecord {
        ["approval_id": .string("approval-1"), "subject_id": .string("task-1"), "question": .string("Share the complete registered resource with this recipient?"), "status": .string("presenting")]
    }

    static func changedApprovalPreventsWrite() async throws {
        for field in ["question", "subject_id"] {
            seed("changed-approval-" + field)
            let store = WorkspaceStore()
            await refreshAllowingSharing(store)
            let shown = approvalFixture()
            var latest = shown
            latest[field] = .string(field == "question" ? "Changed question" : "another-task")
            let refreshed = latest
            network.executeHandler = { _, call in
                try expect(call.method == .collaborationState, "Changed approval submitted a mutation")
                return ["pending_confirmations": .array([.object(refreshed)])]
            }
            await store.confirmApproval(shown, decision: "approve")
            try expect(network.calls.count == 1 && network.reservedCalls.isEmpty, "An obsolete approval was reserved or submitted")
            try expect(store.error != nil, "Changed approval failed without explaining that it needs re-reading")
        }
    }

    static func unchangedApprovalIsRevalidated() async throws {
        seed("approval-revalidated")
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
        let shown = approvalFixture()
        network.executeHandler = { _, call in
            if call.method == .collaborationState {
                return ["pending_confirmations": .array([.object(shown)])]
            }
            try expect(call.method == .approvalRespond && call.params == ["approval_id": .string("approval-1"), "decision": .string("approve")], "Approval write did not preserve the exact decision and immutable subject")
            return ["approval_id": .string("approval-1"), "decision": .string("allow"), "status": .string("approved_once")]
        }
        await store.confirmApproval(shown, decision: "approve")
        try expect(network.calls.map(\.method) == [.collaborationState, .approvalRespond], "Approval was submitted before re-reading its current question")
        try expect(network.reservedCalls.count == 1 && network.reservedCalls.first?.method == .approvalRespond, "Approval read was incorrectly reserved as a business mutation")
    }

    static func accountChangesDuringReservation() async throws {
        seed("reservation-account")
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
        let gate = Gate()
        network.reserveHandler = { _, call, conversation in
            await gate.wait()
            return WorkspaceOperation(call: call, conversationId: conversation)
        }
        let writing = Task { await store.performAction(.inboxMarkRead, params: ["message_id": .string("message-1")]) }
        try await gate.waitUntilEntered()
        network.currentUser = SessionUser(id: "next-account", email: "next@example.com")
        let requestCount = network.requests.count
        gate.release()
        await writing.value
        try expect(network.calls.isEmpty && network.requests.count == requestCount, "An obsolete account's reserved operation was sent under the new account")
    }

    static func accountChangesDuringMutation() async throws {
        seed("mutation-account")
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
        let gate = Gate()
        network.executeHandler = { _, _ in await gate.wait(); return ["message_id": .string("message-1"), "status": .string("read")] }
        let writing = Task { await store.performAction(.inboxMarkRead, params: ["message_id": .string("message-1")]) }
        try await gate.waitUntilEntered()
        network.currentUser = SessionUser(id: "next-account", email: "next@example.com")
        let requestCount = network.requests.count
        gate.release()
        await writing.value
        try expect(network.requests.count == requestCount, "An old mutation updated the new account's ledger or refreshed its content")
        try expect(!store.canAct(.inboxMarkRead), "An obsolete store still permits mutation actions")
    }

    static func hiddenRecordFiltering() async throws {
        seed("hidden-records")
        let contacts: [RemoteRecord] = [
            ["contact_id": .string("hidden-contact"), "urn": .string("urn:agent:hidden")],
            ["contact_id": .string("shown-contact"), "urn": .string("urn:agent:shown")]
        ]
        network.workspaces["a"]?.snapshots["contacts.list"] = WorkspaceSnapshot(data: ["contacts": .array(contacts.map(JSONValue.object))], time: 200)
        network.workspaces["a"]?.recordStates = [
            WorkspaceRecordState(kind: "contact", id: "hidden-contact", deleted: true),
            WorkspaceRecordState(kind: "collaboration", id: "task-1", deleted: true, relatedIds: ["collaboration-1"])
        ]
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
        try expect(store.contacts.map { $0.string("contact_id") } == ["shown-contact"], "Hidden contact remained selectable")
        try expect(store.isRecordHidden(kind: "collaboration", id: "collaboration-1"), "Related collaboration ID bypassed its hidden task state")
        try expect(!store.isRecordHidden(kind: "contact", id: "task-1"), "A hidden state affected a different record kind")
        network.workspaces["a"]?.recordStates?[0].deleted = false
        await refreshAllowingSharing(store)
        try expect(store.contacts.count == 2 && !store.isRecordHidden(kind: "contact", id: "hidden-contact"), "Restored account record stayed hidden")
    }

    static func combinedSnapshotPrecedence() async throws {
        seed("snapshot-precedence")
        let old: RemoteRecord = ["contact_id": .string("old-contact")]
        let fresh: RemoteRecord = ["contact_id": .string("new-contact")]
        let message: RemoteRecord = ["message_id": .string("new-message"), "text": .string("An authenticated message")]
        let request: RemoteRecord = ["request_id": .string("new-request"), "status": .string("pending")]
        network.workspaces["a"]?.snapshots["contacts.list"] = WorkspaceSnapshot(data: ["contacts": .array([.object(old)])], time: 100)
        network.workspaces["a"]?.snapshots["inbox.list"] = WorkspaceSnapshot(data: ["messages": .array([])], time: 100)
        network.workspaces["a"]?.snapshots["collaboration.state"] = WorkspaceSnapshot(data: ["contacts": .array([.object(fresh)]), "inbox": .array([.object(message)]), "contact_requests": .array([.object(request)])], time: 200)
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
        try expect(store.contacts.first?.string("contact_id") == "new-contact", "Older standalone contact snapshot hid fresh combined state")
        try expect(store.inbox.first?.string("message_id") == "new-message", "Combined inbox array was discarded or older standalone inbox won")
        try expect(store.contactRequests.first?.string("request_id") == "new-request", "Combined contact request state was discarded")
        network.workspaces["a"]?.snapshots["inbox.list"] = WorkspaceSnapshot(data: ["messages": .array([.object(["message_id": .string("newest-message")])])], time: 300)
        network.workspaces["a"]?.snapshots["contacts.requests"] = WorkspaceSnapshot(data: ["requests": .array([.object(["request_id": .string("legacy-newest-request")])])], time: 300)
        await refreshAllowingSharing(store)
        try expect(store.inbox.first?.string("message_id") == "newest-message", "Newer standalone inbox did not replace combined state")
        try expect(store.contactRequests.first?.string("request_id") == "legacy-newest-request", "Legacy requests list key was not accepted")
    }

    static func conversationDraftIsolation() async throws {
        seed("conversation-drafts")
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
        store.draft = "First conversation's unfinished text"
        store.saveDraft()
        await store.selectConversation("conversation-b")
        try expect(store.draft.isEmpty, "Switching conversations leaked another conversation's text")
        store.draft = "Second conversation's unfinished text"
        store.saveDraft()
        await store.selectConversation(nil)
        try expect(store.draft.isEmpty, "New chat reused an existing conversation's draft")
        store.draft = "Not yet submitted new conversation"
        store.saveDraft()
        await store.selectConversation("conversation-a")
        try expect(store.draft == "First conversation's unfinished text", "Original conversation draft was not restored")
        await store.selectConversation("conversation-b")
        try expect(store.draft == "Second conversation's unfinished text", "Second conversation draft was overwritten")
        await store.selectConversation(nil)
        try expect(store.draft == "Not yet submitted new conversation", "New conversation draft was not independently retained")
        await store.selectConversation("conversation-a")
        let restarted = WorkspaceStore()
        await refreshAllowingSharing(restarted)
        try expect(restarted.conversationID == "conversation-a" && restarted.draft == "First conversation's unfinished text", "Restart did not restore the active conversation's draft")
    }

    static func savedDraftFallback() async throws {
        seed("account-draft")
        network.workspaces["a"]?.activeConversationState = WorkspaceConversationState(draft: "Previously saved on another device")
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
        try expect(store.draft == "Previously saved on another device", "An account draft was not restored without a local edit")
        store.draft = "This device's unsynchronized edit"
        store.saveDraft()
        network.workspaces["a"]?.activeConversationState?.draft = "A delayed account draft"
        await refreshAllowingSharing(store)
        try expect(store.draft == "This device's unsynchronized edit", "Polling replaced an unsynchronized edit with an account snapshot")
        let restarted = WorkspaceStore()
        await refreshAllowingSharing(restarted)
        try expect(restarted.draft == "This device's unsynchronized edit", "Restart discarded an unsynchronized local edit")
    }

    static func delayedPolicyReadAfterResume() async throws {
        seed("policy-ordering")
        let outdated: RemoteRecord = ["status": .string("legacy"), "paused": .bool(true), "can_use_workbench": .bool(false)]
        let gate = Gate()
        network.policyHandler = { await gate.wait(); return outdated }
        let store = WorkspaceStore()
        let reading = Task { await refreshAllowingSharing(store) }
        try await gate.waitUntilEntered()
        await store.changePolicy("resume")
        try expect(store.policyAccess, "Explicit resume did not enable current policy access")
        gate.release()
        await reading.value
        try expect(store.policyAccess && store.policy?.bool("paused") == false, "An older GET reversed the successful explicit resume")
    }

    static func unresolvedCollaborationBlocksOtherActions() async throws {
        seed("collaboration-unknown")
        let original = PendingCall(method: .collaborationExecute, params: ["action": .string("dispatch"), "operation_id": .string("operation-1")])
        let saved = WorkspaceOperation(call: original, phase: "uncertain", retryable: true, createdAt: Date().timeIntervalSince1970 * 1000)
        network.workspaces["a"]?.operations = [saved]
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
        await store.performAction(.collaborationExecute, params: ["action": .string("pause_worker"), "task_id": .string("task-1")])
        try expect(network.calls.isEmpty && network.reservedCalls.isEmpty, "A different collaboration action bypassed the unresolved business write")
        network.executeHandler = { _, call in
            try expect(call == original, "Explicit retry altered the original unknown collaboration request")
            return ["status": .string("uncertain")]
        }
        await store.retryAction(saved)
        try expect(network.calls.count == 1 && network.reservedCalls.first == original, "The original retry was blocked or changed while another action was prevented")
    }

    static func draftEntries() -> [Data] { SecureStore.memory.filter { $0.key.contains(":draft.") }.map(\.value) }

    static func confirmedDraftReleasesLocalOverride() async throws {
        seed("confirmed-draft")
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
        store.draft = "Now saved in the account"
        store.saveDraft()
        await store.syncDraft()
        try expect(draftEntries().isEmpty, "A confirmed draft remained a permanent local override")
        network.workspaces["a"]?.activeConversationState?.draft = "Updated later on another device"
        let restarted = WorkspaceStore()
        await refreshAllowingSharing(restarted)
        try expect(restarted.draft == "Updated later on another device", "A stale confirmed local draft replaced newer account content")
    }

    static func editingDuringDraftSave() async throws {
        seed("draft-save-edit")
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
        store.draft = "First saved version"
        store.saveDraft()
        let gate = Gate()
        network.conversationUpdateHandler = { id, _, patch in
            await gate.wait()
            network.workspaces[id]?.activeConversationState = WorkspaceConversationState(draft: patch.string("draft"))
            return ["state": .object(patch)]
        }
        let saving = Task { await store.syncDraft() }
        try await gate.waitUntilEntered()
        store.draft = "A newer local edit"
        store.saveDraft()
        gate.release()
        await saving.value
        try expect(store.draft == "A newer local edit", "An earlier save acknowledgement replaced newer input")
        try expect(draftEntries().contains(Data("A newer local edit".utf8)), "An earlier acknowledgement erased the newer recovery draft")
        let restarted = WorkspaceStore()
        await refreshAllowingSharing(restarted)
        try expect(restarted.draft == "A newer local edit", "Restart lost the draft edited during the save")
    }

    static func accountChangesDuringDraftSave() async throws {
        seed("draft-save-account")
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
        store.draft = "Previous account's local recovery"
        store.saveDraft()
        let gate = Gate()
        network.conversationUpdateHandler = { _, _, patch in await gate.wait(); return ["state": .object(patch)] }
        let saving = Task { await store.syncDraft() }
        try await gate.waitUntilEntered()
        network.currentUser = SessionUser(id: "next-account", email: "next@example.com")
        let requestCount = network.requests.count
        gate.release()
        await saving.value
        try expect(network.requests.count == requestCount, "Previous draft save issued requests in the new account")
        try expect(draftEntries().contains(Data("Previous account's local recovery".utf8)), "An obsolete acknowledgement erased the previous account's recovery")
    }

    static func newConversationAccountDraft() async throws {
        seed("new-account-draft")
        network.workspaces["a"]?.activeConversationId = ""
        network.workspaces["a"]?.conversation = nil
        network.workspaces["a"]?.activeConversationState = WorkspaceConversationState(draft: "The unsent account draft")
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
        try expect(store.conversationID.isEmpty && store.draft == "The unsent account draft", "A new-chat account draft was lost before an ID existed")
        try expect(store.canSubmit, "Hydrated new-chat draft is incorrectly prevented from sending")
        try expect(network.calls.isEmpty, "Restoring an account draft automatically sent it")
    }

    static func clearedDraftSurvivesSwitch() async throws {
        seed("cleared-draft")
        network.workspaces["a"]?.activeConversationState = WorkspaceConversationState(draft: "Text the user chose to clear")
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
        store.draft = ""
        store.saveDraft()
        network.conversationUpdateHandler = { _, _, _ in throw URLError(.notConnectedToInternet) }
        await store.selectConversation("conversation-b")
        await store.selectConversation("conversation-a")
        try expect(store.draft.isEmpty, "A failed empty-draft save restored text that the user had cleared")
        let restarted = WorkspaceStore()
        await refreshAllowingSharing(restarted)
        try expect(restarted.draft.isEmpty, "Restart lost the local empty-draft tombstone")
    }

    static func draftSaveQueuePreservesOrder() async throws {
        seed("draft-save-queue")
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
        let gate = Gate()
        var sentTexts: [String] = []
        network.conversationUpdateHandler = { id, conversation, patch in
            let text = patch.string("draft")
            sentTexts.append(text)
            if sentTexts.count == 1 { await gate.wait() }
            network.conversationStates[id, default: [:]][conversation ?? ""] = WorkspaceConversationState(draft: text)
            network.workspaces[id]?.activeConversationState = WorkspaceConversationState(draft: text)
            return ["state": .object(patch)]
        }
        store.draft = "Older save"
        store.saveDraft()
        let first = Task { await store.syncDraft() }
        try await gate.waitUntilEntered()
        first.cancel()
        store.draft = "Newer save"
        store.saveDraft()
        var secondStarted = false
        let second = Task { secondStarted = true; await store.syncDraft() }
        for _ in 0..<100 where !secondStarted { await Task.yield() }
        for _ in 0..<10 { await Task.yield() }
        let sentBeforeRelease = sentTexts
        gate.release()
        await first.value
        await second.value
        try expect(secondStarted && sentBeforeRelease == ["Older save"], "A newer save raced an older request still able to commit")
        try expect(sentTexts == ["Older save", "Newer save"], "Cancelled view task discarded a save or reordered account writes")
        try expect(network.workspaces["a"]?.activeConversationState?.draft == "Newer save", "The account finished with the older draft")
    }

    static func foreignSubmissionPreservesScopedDraft() async throws {
        seed("foreign-send-draft")
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
        store.draft = "Unfinished original conversation"
        store.saveDraft()
        let foreign = newerRemoteSubmission()
        network.workspaces["a"]?.submission = foreign
        network.workspaces["a"]?.activeConversationId = foreign.conversationId
        network.workspaces["a"]?.conversation = nil
        network.workspaces["a"]?.activeConversationState = WorkspaceConversationState(draft: "Other conversation's saved draft")
        await refreshAllowingSharing(store)
        try expect(store.submission?.call == foreign.call && store.conversationID == foreign.conversationId, "Foreign unresolved send was not restored")
        try expect(store.draft != "Unfinished original conversation", "Original conversation's text leaked into the foreign send")
        let updatesBefore = network.requests.filter { $0.method == "conversation-update" }.count
        await store.syncDraft()
        try expect(network.requests.filter { $0.method == "conversation-update" }.count == updatesBefore, "Unhydrated foreign context overwrote an account draft")
        network.workspaces["a"]?.submission = nil
        network.workspaces["a"]?.conversation = ["conversation_id": .string(foreign.conversationId), "turns": .array([.object(turn(foreign.turnId, time: 20, status: "completed"))])]
        await refreshAllowingSharing(store)
        try expect(store.submission == nil && store.draft == "Other conversation's saved draft", "A resolved foreign send did not hydrate its own account draft")
        await store.selectConversation("conversation-a")
        try expect(store.draft == "Unfinished original conversation", "Foreign recovery discarded the original scoped draft")
    }

    static func remotelyDeletedConversation() async throws {
        seed("remote-deletion")
        savedHistoryFixture()
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
        store.focusTurnID = "saved-terminal-turn"
        network.workspaces["a"]?.activeConversationState = WorkspaceConversationState(deleted: true)
        await refreshAllowingSharing(store)
        try expect(store.conversationID.isEmpty && store.turns.isEmpty && store.focusTurnID == nil, "Authoritative deletion preserved or resurrected a cached transcript")
    }

    static func legacyDraftMigration() async throws {
        seed("legacy-draft")
        let scope = network.baseUrl + "\u{0}" + (network.currentUser?.id ?? "")
        let hash = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        let journal = SecureStore(namespace: "agent-workspace." + hash)
        try journal.set(Data("An existing release's unfinished draft".utf8), for: "draft.a")
        let store = WorkspaceStore()
        await refreshAllowingSharing(store)
        try expect(store.draft == "An existing release's unfinished draft", "Upgrade discarded a legacy local draft")
        let legacyValue = try journal.data(key: "draft.a")
        let scopedValue = try journal.data(key: "draft.a.conversation-a")
        try expect(legacyValue == nil, "Legacy draft was not moved out of the unscoped slot")
        try expect(scopedValue == Data("An existing release's unfinished draft".utf8), "Legacy draft was not migrated to the saved active conversation")
    }

    static func required<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw HarnessFailure.message(message) }
        return value
    }
}
