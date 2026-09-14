import Foundation
import Combine
import CryptoKit
import AgentWorkspaceKit

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published var connections: [WorkspaceConnection] = []
    @Published var selectedAgentID: String?
    @Published var workspace: WorkspaceAgent?
    @Published var isLoading = false
    @Published var busy: String?
    @Published var error: String?
    @Published var connectionError: String?
    @Published var draft = ""
    @Published var submission: WorkspaceSubmission?
    @Published var conversationID = ""
    @Published var hasEarlierTurns = false
    @Published var tab = 0
    let demo: Bool
    private let network = NetworkManager.shared
    private var cache: [String: WorkspaceAgent] = [:]
    private var generation = 0
    private var fetching = false
    private var earlierLoaded = false
    private var localRecoveryReady = false
    private var resolved = Set<String>()
    private let journal: SecureStore
    private let accountScope: String
    private let sessionRevision: Int
    private var scopeIsCurrent: Bool {
        demo || (network.isAuthenticated && sessionRevision == network.sessionRevision && accountScope == network.baseUrl + "\u{0}" + (network.currentUser?.id ?? "signed-out"))
    }

    init(demo: Bool = false) {
        self.demo = demo
        let scope = NetworkManager.shared.baseUrl + "\u{0}" + (NetworkManager.shared.currentUser?.id ?? "signed-out")
        accountScope = scope
        sessionRevision = NetworkManager.shared.sessionRevision
        let digest = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        journal = SecureStore(namespace: "agent-workspace." + digest)
        #if DEBUG
        if demo { workspace = DemoWorkspace.agent; connections = [DemoWorkspace.agent.agent]; selectedAgentID = workspace?.agent.id; conversationID = workspace?.activeConversationId ?? "" }
        #endif
    }

    var selectedAgent: WorkspaceConnection? { connections.first { $0.id == selectedAgentID } }
    var capabilities: RemoteRecord? { workspace?.snapshots["capabilities"]?.data }
    var turns: [RemoteRecord] { workspace?.conversation?.records("turns") ?? [] }
    var collaboration: RemoteRecord { workspace?.snapshots["collaboration.state"]?.data ?? [:] }
    var contacts: [RemoteRecord] { workspace?.snapshots["contacts.list"]?.data.records("contacts") ?? collaboration.records("contacts") }
    var inbox: [RemoteRecord] { workspace?.snapshots["inbox.list"]?.data.records("messages") ?? collaboration.records("messages") }
    var pendingCount: Int { collaboration.records("pending_confirmations").count }
    var canSend: Bool {
        guard let workspace else { return false }
        return !demo && scopeIsCurrent && available(.conversationSend) && workspace.identity.virtualUrn != nil && pairingAllowsSend(capabilities: capabilities, sync: workspace.sync)
    }
    var canSubmit: Bool { canSend && localRecoveryReady && busy == nil && submission == nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.count <= 8000 && draft.utf8.count <= 24000 }
    func available(_ method: RPCMethod) -> Bool { capabilities?.records("methods").contains { $0.string("name") == method.rawValue && $0.bool("available") } ?? false }

    func run() async {
        guard !demo, scopeIsCurrent else { return }
        while !Task.isCancelled && scopeIsCurrent {
            await refresh()
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
        }
    }

    func refresh(schedule: Bool = false) async {
        guard !demo, scopeIsCurrent, !fetching else { return }
        fetching = true
        isLoading = connections.isEmpty
        defer { fetching = false; isLoading = false }
        let version = generation
        do {
            if schedule {
                try await network.scheduleSync(agentId: selectedAgentID)
                try Task.checkCancellation()
                guard scopeIsCurrent else { return }
            }
            let overview = try await network.fetchOverview()
            try Task.checkCancellation()
            guard version == generation, scopeIsCurrent else { return }
            connections = overview.connections
            if selectedAgentID == nil || !connections.contains(where: { $0.id == selectedAgentID }) {
                guard busy == nil else { return }
                selectedAgentID = connections.first?.id
                localRecoveryReady = false
                draft = ""
                earlierLoaded = false
                hasEarlierTurns = false
                workspace = nil
                conversationID = ""
                submission = nil
            }
            if let id = selectedAgentID {
                if !localRecoveryReady { restoreLocal(agentID: id) }
                let data = try await network.fetchWorkspace(agentId: id, conversationId: workspace == nil && submission == nil ? nil : conversationID)
                try Task.checkCancellation()
                guard version == generation, scopeIsCurrent, id == selectedAgentID else { return }
                apply(data)
            }
            connectionError = nil
        } catch is CancellationError { } catch {
            if version == generation && scopeIsCurrent { self.connectionError = error.localizedDescription }
        }
    }

    func selectAgent(_ id: String) async {
        guard scopeIsCurrent, id != selectedAgentID, busy == nil else { return }
        saveDraft()
        generation += 1
        selectedAgentID = id
        localRecoveryReady = false
        workspace = cache[id]
        conversationID = workspace?.activeConversationId ?? ""
        earlierLoaded = false
        hasEarlierTurns = workspace?.hasEarlierTurns ?? false
        submission = nil
        draft = ""
        error = nil
        connectionError = nil
        restoreLocal(agentID: id)
        await readSaved()
    }

    private func apply(_ incoming: WorkspaceAgent) {
        guard scopeIsCurrent, incoming.agent.id == selectedAgentID else { return }
        var data = incoming
        if let previous = workspace, previous.agent.id == data.agent.id {
            data.snapshots = mergeSnapshots(previous: previous.snapshots, incoming: data.snapshots)
            if let old = previous.conversation, old.string("conversation_id") == conversationID {
                if let next = data.conversation, next.string("conversation_id") == conversationID {
                    data.conversation?["turns"] = .array(mergeTurns(earlier: old.records("turns"), latest: next.records("turns")).map(JSONValue.object))
                } else {
                    // A cache read made before acceptance may not contain the new conversation yet.
                    data.conversation = old
                }
            }
        } else if submission == nil {
            conversationID = data.activeConversationId
        }
        // Another device may already have submitted a new request. Reconcile this device's
        // journal first, while the returned transcript still proves which local text was accepted.
        reconcileSubmission(in: incoming.conversation)
        if busy != "conversation.send", let saved = data.submission,
           !resolved.contains(saved.call.requestId),
           submission == nil || submission?.call.requestId == saved.call.requestId {
            submission = saved
            submission?.phase = "uncertain"
            conversationID = saved.conversationId
            persistSubmission()
        }
        // An unrelated server submission must never overwrite an unverified local journal.
        reconcileSubmission(in: incoming.conversation)
        if let conversation = data.conversation, conversation.string("conversation_id") != conversationID { data.conversation = nil }
        if !earlierLoaded { hasEarlierTurns = data.hasEarlierTurns }
        data.activeConversationId = conversationID
        workspace = data
        cache[data.agent.id] = data
    }

    private func readSaved() async {
        guard let id = selectedAgentID, !demo, scopeIsCurrent, localRecoveryReady else { return }
        let version = generation
        do {
            let data = try await network.fetchWorkspace(agentId: id, conversationId: workspace == nil && submission == nil ? nil : conversationID)
            try Task.checkCancellation()
            guard version == generation, scopeIsCurrent else { return }
            apply(data)
            connectionError = nil
        } catch is CancellationError { } catch { if version == generation && scopeIsCurrent { self.connectionError = error.localizedDescription } }
    }

    func addConnection(name: String, urn: String) async throws {
        guard !demo, scopeIsCurrent else { return }
        let created = try await network.createConnection(name: name.trimmingCharacters(in: .whitespacesAndNewlines), urn: urn.trimmingCharacters(in: .whitespacesAndNewlines))
        guard scopeIsCurrent else { throw CancellationError() }
        let overview = try await network.fetchOverview()
        guard scopeIsCurrent else { throw CancellationError() }
        connections = overview.connections
        await selectAgent(created.string("id"))
    }

    func bindIdentity() async {
        guard scopeIsCurrent, let id = selectedAgentID, busy == nil, !demo else { return }
        busy = "identity"; error = nil
        defer { busy = nil }
        do {
            let identity = try await network.bindIdentity(agentId: id)
            guard scopeIsCurrent, selectedAgentID == id else { return }
            workspace?.identity = identity
            await readSaved()
        } catch { if scopeIsCurrent { self.error = error.localizedDescription } }
    }

    func invoke(_ method: RPCMethod, params: RemoteRecord = [:]) async {
        guard scopeIsCurrent, let id = selectedAgentID, busy == nil, !demo, method != .conversationSend else { return }
        busy = method.rawValue; error = nil
        let version = generation
        defer { busy = nil }
        do {
            let result = try await network.execute(agentId: id, call: PendingCall(method: method, params: params))
            guard version == generation, scopeIsCurrent else { return }
            if method == .conversationGet, result.string("conversation_id") == conversationID {
                var conversation = result
                conversation["turns"] = .array(mergeTurns(earlier: turns, latest: result.records("turns")).map(JSONValue.object))
                workspace?.conversation = conversation
                if let pending = submission, result.records("turns").contains(where: { $0.string("turn_id") == pending.turnId }) { resolve(pending) }
            }
            // Durable server snapshots determine freshness, not the time this device reads a cache.
            if method == .capabilities { try await network.scheduleSync(agentId: id) }
            await readSaved()
        } catch { if version == generation && scopeIsCurrent { self.error = error.localizedDescription } }
    }

    func selectConversation(_ id: String?) async {
        guard scopeIsCurrent, let agentID = selectedAgentID, busy == nil, submission == nil, !demo else { return }
        busy = "selection"; error = nil
        defer { busy = nil }
        do {
            let data = try await network.selectConversation(agentId: agentID, conversationId: id)
            guard scopeIsCurrent else { return }
            generation += 1
            conversationID = data.activeConversationId
            workspace?.conversation = nil
            earlierLoaded = false
            apply(data)
        } catch { if scopeIsCurrent { self.error = error.localizedDescription } }
    }

    func openConversation(_ id: String) async {
        guard scopeIsCurrent, let agentID = selectedAgentID, busy == nil, submission == nil, !demo else { return }
        guard id.range(of: "^[A-Za-z0-9._:-]{1,128}$", options: .regularExpression) != nil else { error = "对话 ID 仅支持字母、数字和 . _ : -，最多 128 位。"; return }
        busy = "conversation.get"; error = nil
        let version = generation
        defer { busy = nil }
        do {
            // Remote-only conversations must be read and saved before the workspace can select them.
            let result = try await network.execute(agentId: agentID, call: PendingCall(method: .conversationGet, params: ["conversation_id": .string(id)]))
            guard scopeIsCurrent, version == generation else { return }
            guard result.string("conversation_id") == id else {
                error = "返回的对话与请求不一致，请稍后重试。"
                return
            }
            let data = try await network.selectConversation(agentId: agentID, conversationId: id)
            guard scopeIsCurrent, version == generation else { return }
            generation += 1
            conversationID = id
            workspace?.conversation = result
            earlierLoaded = false
            apply(data)
        } catch { if scopeIsCurrent, version == generation { self.error = error.localizedDescription } }
    }

    func loadEarlier() async {
        guard scopeIsCurrent, let id = selectedAgentID, let first = turns.first, hasEarlierTurns, busy == nil, !demo else { return }
        busy = "earlier"; error = nil
        let version = generation
        defer { busy = nil }
        do {
            let data = try await network.fetchWorkspace(agentId: id, conversationId: conversationID, before: first.string("turn_id"))
            guard version == generation, scopeIsCurrent, data.conversation?.string("conversation_id") == conversationID else { return }
            workspace?.conversation?["turns"] = .array(mergeTurns(earlier: data.conversation?.records("turns") ?? [], latest: turns).map(JSONValue.object))
            earlierLoaded = true
            hasEarlierTurns = data.hasEarlierTurns
        } catch { if scopeIsCurrent { self.error = error.localizedDescription } }
    }

    func send(retry: Bool = false) async {
        guard scopeIsCurrent, localRecoveryReady, let id = selectedAgentID, let urn = workspace?.identity.virtualUrn, canSend, busy == nil else { return }
        let item: WorkspaceSubmission
        if retry {
            guard var existing = submission, existing.retryable else { return }
            existing.phase = "sending"; item = existing
        } else {
            guard canSubmit else { return }
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            var params: RemoteRecord = ["text": .string(text)]
            if !conversationID.isEmpty { params["conversation_id"] = .string(conversationID) }
            let call = PendingCall(method: .conversationSend, params: params)
            let hash = SHA256.hash(data: Data((urn + "\u{0}" + call.requestId).utf8)).map { String(format: "%02x", $0) }.joined()
            item = WorkspaceSubmission(call: call, text: text, conversationId: conversationID.isEmpty ? call.requestId : conversationID, turnId: "turn-" + String(hash.prefix(40)), phase: "sending", retryable: true)
        }
        // Write-ahead journal prevents a terminated app from silently issuing a new action.
        do { try journal.set(JSONEncoder().encode(item), for: "submission." + id) }
        catch { self.error = "无法安全保存发送记录，请稍后重试。"; return }
        busy = "conversation.send"; submission = item; error = nil
        conversationID = item.conversationId
        defer { busy = nil }
        do {
            let result = try await network.execute(agentId: id, call: item.call)
            guard scopeIsCurrent else { return }
            guard result.string("status") == "submitted", result.string("conversation_id") == item.conversationId, result.string("turn_id") == item.turnId else {
                submission?.phase = "uncertain"; submission?.retryable = false; persistSubmission()
                error = "受理回执尚未匹配，请读取对话核实。"; return
            }
            var optimistic = result
            optimistic["text"] = .string(item.text)
            optimistic["created_at"] = .number(Date().timeIntervalSince1970)
            workspace?.conversation = ["conversation_id": .string(item.conversationId), "turns": .array(mergeTurns(earlier: turns, latest: [optimistic]).map(JSONValue.object))]
            resolve(item)
            try? await network.scheduleSync(agentId: id)
            await readSaved()
        } catch let failure as ControlCallError {
            guard scopeIsCurrent else { return }
            self.error = failure.localizedDescription
            if failure.uncertain { submission?.phase = "uncertain"; submission?.retryable = failure.retryable; persistSubmission() }
            else { resolve(item, clearDraft: false) }
        } catch {
            guard scopeIsCurrent else { return }
            self.error = "连接中断，尚不能确认是否已受理。请先核实对话。"
            submission?.phase = "uncertain"; persistSubmission()
        }
    }

    func inspectSubmission() async {
        guard scopeIsCurrent, let pending = submission else { return }
        conversationID = pending.conversationId
        await invoke(.conversationGet, params: ["conversation_id": .string(pending.conversationId)])
    }

    func dismissSubmission() async {
        guard scopeIsCurrent, let id = selectedAgentID, let pending = submission, !pending.retryable, busy == nil, !demo else { return }
        busy = "dismiss"; defer { busy = nil }
        do {
            let data = try await network.dismissSubmission(agentId: id, requestId: pending.call.requestId)
            guard scopeIsCurrent, selectedAgentID == id else { return }
            resolve(pending)
            apply(data)
        } catch { if scopeIsCurrent { self.error = error.localizedDescription } }
    }

    private func reconcileSubmission(in conversation: RemoteRecord?) {
        guard let pending = submission,
              conversation?.string("conversation_id") == pending.conversationId,
              conversation?.records("turns").contains(where: { $0.string("turn_id") == pending.turnId }) == true else { return }
        resolve(pending)
    }

    private func resolve(_ item: WorkspaceSubmission, clearDraft: Bool = true) {
        resolved.insert(item.call.requestId)
        submission = nil
        if clearDraft && draft.trimmingCharacters(in: .whitespacesAndNewlines) == item.text { draft = ""; saveDraft() }
        if localRecoveryReady, let id = selectedAgentID { try? journal.remove(key: "submission." + id) }
    }
    private func persistSubmission() {
        guard scopeIsCurrent, localRecoveryReady, let id = selectedAgentID, let submission, !demo else { return }
        do { try journal.set(JSONEncoder().encode(submission), for: "submission." + id) }
        catch { self.error = "发送记录暂时无法保存，请先核实对话结果。" }
    }
    private func restoreLocal(agentID: String) {
        do {
            let savedSubmission = try journal.data(key: "submission." + agentID).map { try JSONDecoder().decode(WorkspaceSubmission.self, from: $0) }
            let savedDraft = try journal.data(key: "draft." + agentID).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            submission = savedSubmission
            submission?.phase = "uncertain"
            conversationID = submission?.conversationId ?? conversationID
            draft = savedDraft
            localRecoveryReady = true
        } catch {
            localRecoveryReady = false
            self.error = "暂时无法读取本机草稿或发送记录。恢复前已暂停发送，请稍后刷新。"
        }
    }
    func saveDraft() {
        guard let id = selectedAgentID, !demo, scopeIsCurrent, localRecoveryReady else { return }
        do { if draft.isEmpty { try journal.remove(key: "draft." + id) } else { try journal.set(Data(draft.utf8), for: "draft." + id) } }
        catch { self.error = "草稿暂时无法保存到此设备。" }
    }
}
