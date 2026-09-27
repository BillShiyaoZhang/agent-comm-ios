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
    @Published var policy: RemoteRecord?
    @Published var policyError: String?
    @Published var notifications: [RemoteRecord] = []
    @Published var notificationCounts: RemoteRecord = [:]
    @Published var notificationError: String?
    @Published var notificationFilter = "all"
    @Published var notificationBefore: Double?
    @Published var actionOperations: [WorkspaceOperation] = []
    @Published var actionResult: String?
    @Published var actionResponse: RemoteRecord?
    @Published var collaborationDescription: RemoteRecord = [:]
    @Published var focusTurnID: String?
    @Published var collaborationFocusID: String?
    @Published var activity: RemoteRecord = [:]
    let demo: Bool
    private let network = NetworkManager.shared
    private var cache: [String: WorkspaceAgent] = [:]
    private var generation = 0
    private var fetching = false
    private var earlierLoaded = false
    private var localRecoveryReady = false
    private var draftHydrated = false
    private var legacyDraft: String?
    private var lastSyncedDraft: String?
    private var draftSaveTask: Task<Void, Never>?
    private var draftSaveID: UUID?
    private var resolved = Set<String>()
    private var operationsReady = false
    private var policyCheckedAt = Date.distantPast
    private var changingPolicy = false
    private var policyRevision = 0
    private var loadingNotifications = false
    private var loadedNotificationFilter = "all"
    private var notificationHistoryLoaded = false
    private var activityCheckedAt = Date.distantPast
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
        if demo {
            workspace = DemoWorkspace.agent; connections = [DemoWorkspace.agent.agent]; selectedAgentID = workspace?.agent.id; conversationID = workspace?.activeConversationId ?? ""
            notificationCounts = ["unread": 2, "pending": 1]
            notifications = [
                ["id": .string(String(repeating: "a", count: 64)), "agentId": "demo-hermes", "agentName": "Hermes", "revision": 1, "unread": true, "state": "open", "title": "评审安排需要你确认", "summary": "请核对会议范围、时间和确切接收方。", "target": ["kind": "approval", "id": "approval-1"], "updatedAt": 1790493571000],
                ["id": .string(String(repeating: "b", count: 64)), "agentId": "demo-hermes", "agentName": "Hermes", "revision": 1, "unread": true, "state": "resolved", "title": "讨论提纲已整理", "summary": "对话回合已经完成，可以回到原对话查看结果。", "target": ["kind": "conversation", "id": "conversation-demo", "turn_id": "turn-demo-2"], "updatedAt": 1790493471000]
            ]
        }
        #endif
    }

    var selectedAgent: WorkspaceConnection? { connections.first { $0.id == selectedAgentID } }
    var capabilities: RemoteRecord? { workspace?.snapshots["capabilities"]?.data }
    var turns: [RemoteRecord] { workspace?.conversation?.records("turns") ?? [] }
    var collaboration: RemoteRecord { workspace?.snapshots["collaboration.state"]?.data ?? [:] }
    var contacts: [RemoteRecord] { currentRecords(method: "contacts.list", key: "contacts").filter { !isRecordHidden(kind: "contact", id: $0.string("contact_id")) } }
    var inbox: [RemoteRecord] { currentRecords(method: "inbox.list", key: "messages") }
    var contactRequests: [RemoteRecord] { currentRecords(method: "contacts.requests", key: "contact_requests") }
    var sentMessages: [RemoteRecord] { collaboration.records("sent_messages") }
    var uncertainActions: [WorkspaceOperation] { actionOperations.filter { ["sending", "uncertain"].contains($0.phase) } }
    var policyAccess: Bool { policy?.bool("can_use_workbench") == true }
    func isRecordHidden(kind: String, id: String) -> Bool {
        workspace?.recordStates?.contains { $0.kind == kind && $0.deleted && ($0.id == id || $0.relatedIds?.contains(id) == true) } == true
    }
    private func currentRecords(method: String, key: String) -> [RemoteRecord] {
        let direct = workspace?.snapshots[method]
        let combined = workspace?.snapshots["collaboration.state"]
        if let combined, combined.time >= (direct?.time ?? -.infinity) {
            if combined.data[key] != nil { return combined.data.records(key) }
            if key == "messages", let value = combined.data["inbox"] {
                return value.arrayValue?.compactMap(\.objectValue) ?? value.objectValue?.records("messages") ?? []
            }
            if key == "contact_requests", combined.data["requests"] != nil { return combined.data.records("requests") }
        }
        if let direct { return direct.data.records(key).isEmpty && key == "contact_requests" ? direct.data.records("requests") : direct.data.records(key) }
        return collaboration.records(key)
    }
    var pendingCount: Int { collaboration.records("pending_confirmations").count }
    var canSend: Bool {
        guard let workspace else { return false }
        return !demo && scopeIsCurrent && policyAccess && available(.conversationSend) && workspace.identity.virtualUrn != nil && pairingAllowsSend(capabilities: capabilities, sync: workspace.sync)
    }
    var canSubmit: Bool { canSend && localRecoveryReady && draftHydrated && busy == nil && submission == nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.count <= 8000 && draft.utf8.count <= 24000 }
    func available(_ method: RPCMethod) -> Bool { capabilities?.records("methods").contains { $0.string("name") == method.rawValue && $0.bool("available") } ?? false }
    func canAct(_ method: RPCMethod) -> Bool {
        !demo && scopeIsCurrent && policyAccess && localRecoveryReady && operationsReady && busy == nil && available(method) && workspace?.identity.virtualUrn != nil && pairingAllowsSend(capabilities: capabilities, sync: workspace?.sync ?? .init())
    }

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
            if !changingPolicy && Date().timeIntervalSince(policyCheckedAt) >= 30 { await refreshPolicy() }
            guard version == generation, scopeIsCurrent else { return }
            if schedule && policyAccess {
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
                draftHydrated = false
                draft = ""
                earlierLoaded = false
                hasEarlierTurns = false
                workspace = nil
                conversationID = ""
                submission = nil
                operationsReady = false
                actionOperations = []
                collaborationDescription = [:]
            }
            if let id = selectedAgentID {
                if !localRecoveryReady { restoreLocal(agentID: id) }
                let data = try await network.fetchWorkspace(agentId: id, conversationId: workspace == nil && submission == nil ? nil : conversationID)
                try Task.checkCancellation()
                guard version == generation, scopeIsCurrent, id == selectedAgentID else { return }
                apply(data)
                if !operationsReady { await loadOperations(agentID: id, version: version) }
            }
            connectionError = nil
        } catch is CancellationError { } catch {
            if version == generation && scopeIsCurrent { self.connectionError = error.localizedDescription }
        }
        if scopeIsCurrent && version == generation {
            await refreshNotifications()
            if Date().timeIntervalSince(activityCheckedAt) >= 30 {
                activityCheckedAt = Date()
                if let value = try? await network.fetchActivity(), scopeIsCurrent, version == generation { activity = value }
            }
        }
    }

    func selectAgent(_ id: String) async {
        guard scopeIsCurrent, id != selectedAgentID, busy == nil else { return }
        saveDraft()
        busy = "draft"
        await syncDraft()
        busy = nil
        guard scopeIsCurrent else { return }
        generation += 1
        selectedAgentID = id
        localRecoveryReady = false
        draftHydrated = false
        legacyDraft = nil
        lastSyncedDraft = nil
        workspace = cache[id]
        conversationID = workspace?.activeConversationId ?? ""
        earlierLoaded = false
        hasEarlierTurns = workspace?.hasEarlierTurns ?? false
        submission = nil
        draft = ""
        error = nil
        connectionError = nil
        operationsReady = false
        actionOperations = []
        actionResult = nil
        collaborationDescription = [:]
        focusTurnID = nil
        collaborationFocusID = nil
        restoreLocal(agentID: id)
        await readSaved()
        await loadOperations(agentID: id, version: generation)
    }

    private func apply(_ incoming: WorkspaceAgent) {
        guard scopeIsCurrent, incoming.agent.id == selectedAgentID else { return }
        var data = incoming
        let oldConversationID = conversationID
        let deletedCurrent = submission == nil && incoming.activeConversationId == conversationID && incoming.activeConversationState?.deleted == true
        if deletedCurrent {
            conversationID = ""
            data.conversation = nil
            data.activeConversationState = nil
            focusTurnID = nil
            earlierLoaded = false
            hasEarlierTurns = false
        }
        if let previous = workspace, previous.agent.id == data.agent.id {
            data.snapshots = mergeSnapshots(previous: previous.snapshots, incoming: data.snapshots)
            if !deletedCurrent, let old = previous.conversation, old.string("conversation_id") == conversationID {
                if let next = data.conversation, next.string("conversation_id") == conversationID {
                    data.conversation?["turns"] = .array(mergeTurns(earlier: old.records("turns"), latest: next.records("turns")).map(JSONValue.object))
                } else {
                    // A cache read made before acceptance may not contain the new conversation yet.
                    data.conversation = old
                }
            }
        } else if submission == nil && !deletedCurrent {
            conversationID = data.activeConversationId
        }
        // Another device may already have submitted a new request. Reconcile this device's
        // journal first, while the returned transcript still proves which local text was accepted.
        reconcileSubmission(in: incoming.conversation)
        if busy != "conversation.send", let saved = data.submission,
           !resolved.contains(saved.call.requestId),
           submission == nil || submission?.call.requestId == saved.call.requestId {
            if conversationID != saved.conversationId {
                saveDraft()
                draftHydrated = false
                lastSyncedDraft = nil
                legacyDraft = nil
                do { draft = try journal.data(key: "draft." + data.agent.id + "." + saved.conversationId).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
                catch { localRecoveryReady = false; self.error = "暂时无法读取待核实对话的草稿。" }
            }
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
        if !draftHydrated || oldConversationID != conversationID {
            if submission == nil { restoreConversationDraft(); draftHydrated = localRecoveryReady }
        }
        if let operations = data.operations, busy == nil {
            actionOperations = operations
            operationsReady = true
        }
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
        guard scopeIsCurrent, policyAccess, let id = selectedAgentID, busy == nil, !demo,
              [.capabilities, .contactsList, .contactsRequests, .collaborationState, .inboxList, .conversationGet, .attentionList].contains(method),
              method == .capabilities || available(method) else { return }
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
        saveDraft()
        busy = "selection"; error = nil
        defer { busy = nil }
        do {
            await syncDraft()
            guard scopeIsCurrent else { return }
            let data = try await network.selectConversation(agentId: agentID, conversationId: id)
            guard scopeIsCurrent else { return }
            generation += 1
            conversationID = data.activeConversationId
            focusTurnID = nil
            workspace?.conversation = nil
            earlierLoaded = false
            apply(data)
            restoreConversationDraft()
        } catch { if scopeIsCurrent { self.error = error.localizedDescription } }
    }

    func openConversation(_ id: String) async {
        guard scopeIsCurrent, policyAccess, available(.conversationGet), let agentID = selectedAgentID, busy == nil, submission == nil, !demo else { return }
        guard id.range(of: "^[A-Za-z0-9._:-]{1,128}$", options: .regularExpression) != nil else { error = "对话 ID 仅支持字母、数字和 . _ : -，最多 128 位。"; return }
        saveDraft()
        busy = "conversation.get"; error = nil
        let version = generation
        defer { busy = nil }
        do {
            await syncDraft()
            guard scopeIsCurrent, version == generation else { return }
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
            focusTurnID = nil
            workspace?.conversation = result
            earlierLoaded = false
            apply(data)
            restoreConversationDraft()
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
        let previousConversationID = conversationID
        busy = "conversation.send"; submission = item; error = nil
        conversationID = item.conversationId
        saveDraft()
        if previousConversationID.isEmpty { try? journal.remove(key: "draft." + id + ".new") }
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
            let restoredConversation = savedSubmission?.conversationId ?? conversationID
            let scopedDraft = try journal.data(key: "draft." + agentID + "." + (restoredConversation.isEmpty ? "new" : restoredConversation)).flatMap { String(data: $0, encoding: .utf8) }
            legacyDraft = try journal.data(key: "draft." + agentID).flatMap { String(data: $0, encoding: .utf8) }
            let savedDraft = scopedDraft ?? legacyDraft ?? ""
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
        guard let id = selectedAgentID, !demo, scopeIsCurrent, localRecoveryReady, draftHydrated else { return }
        let key = "draft." + id + "." + (conversationID.isEmpty ? "new" : conversationID)
        do {
            if draft == lastSyncedDraft { try journal.remove(key: key) }
            else { try journal.set(Data(draft.utf8), for: key) }
            try journal.remove(key: "draft." + id)
        }
        catch { self.error = "草稿暂时无法保存到此设备。" }
    }

    private func restoreConversationDraft() {
        guard scopeIsCurrent, localRecoveryReady, let id = selectedAgentID, !demo, submission == nil else { return }
        do {
            let key = "draft." + id + "." + (conversationID.isEmpty ? "new" : conversationID)
            lastSyncedDraft = workspace?.activeConversationState?.draft
            draft = try journal.data(key: key).flatMap { String(data: $0, encoding: .utf8) } ?? legacyDraft ?? lastSyncedDraft ?? ""
            if legacyDraft != nil { try journal.set(Data(draft.utf8), for: key); try journal.remove(key: "draft." + id); legacyDraft = nil }
        } catch { localRecoveryReady = false; self.error = "暂时无法读取此对话的本机草稿，请刷新后重试。" }
    }

    func syncDraft() async {
        // Metadata saves finish in order even when a view's debounce task is cancelled.
        // Cancelling a HTTP request cannot prove the server did not commit it.
        while let task = draftSaveTask {
            let token = draftSaveID
            await task.value
            if draftSaveID == token { draftSaveTask = nil; draftSaveID = nil }
        }
        guard scopeIsCurrent, localRecoveryReady, draftHydrated, !demo, let id = selectedAgentID, submission == nil, draft.utf8.count <= 24000 else { return }
        let text = draft, conversation = conversationID
        guard text != lastSyncedDraft else { return }
        let token = UUID()
        let task = Task { await persistDraft(agentID: id, conversation: conversation, text: text) }
        draftSaveID = token; draftSaveTask = task
        await task.value
        if draftSaveID == token { draftSaveTask = nil; draftSaveID = nil }
    }

    private func persistDraft(agentID id: String, conversation: String, text: String) async {
        guard scopeIsCurrent else { return }
        do {
            _ = try await network.updateConversation(agentId: id, conversationId: conversation.isEmpty ? nil : conversation, patch: ["draft": .string(text)])
            guard scopeIsCurrent, selectedAgentID == id, conversationID == conversation else { return }
            // The account copy is now authoritative. Only unsynced local edits override it.
            lastSyncedDraft = text
            if draft == text { try journal.remove(key: "draft." + id + "." + (conversation.isEmpty ? "new" : conversation)) }
            workspace?.activeConversationState?.draft = text
        }
        catch is CancellationError { }
        catch { if scopeIsCurrent, selectedAgentID == id, conversationID == conversation, !Task.isCancelled { self.error = "本机草稿已保留，暂时无法同步到账户。" } }
    }

    func refreshPolicy() async {
        guard !demo, scopeIsCurrent, !changingPolicy else { return }
        let version = generation
        let revision = policyRevision
        policyCheckedAt = Date()
        do {
            let value = try await network.fetchPolicy()
            guard version == generation, revision == policyRevision, scopeIsCurrent, !changingPolicy else { return }
            guard ["legacy", "signed"].contains(value.string("status")) else { throw WorkspaceClientError.invalidResponse }
            policy = value; policyError = nil
        } catch {
            guard version == generation, revision == policyRevision, scopeIsCurrent, !changingPolicy else { return }
            policy = nil; policyError = error.localizedDescription
        }
    }

    func changePolicy(_ action: String, displayedHash: String? = nil) async {
        guard !demo, scopeIsCurrent, busy == nil, !changingPolicy else { return }
        if action == "confirm" && (policy?.string("policy_hash") != displayedHash || displayedHash == nil) { return }
        changingPolicy = true; busy = "policy"; policyError = nil
        policyRevision += 1
        defer { changingPolicy = false; busy = nil; policyCheckedAt = Date() }
        do {
            if action == "pause" {
                try await network.pausePolicy()
                guard scopeIsCurrent else { return }
                policy?["paused"] = .bool(true); policy?["can_use_workbench"] = .bool(false)
            } else {
                let body: RemoteRecord = action == "confirm" ? ["policy_hash": .string(displayedHash!), "confirm": .bool(true)] : ["resume": .bool(true)]
                let value = try await network.updatePolicy(body)
                guard scopeIsCurrent else { return }
                policy = value
            }
        } catch { if scopeIsCurrent { policy = nil; policyError = error.localizedDescription } }
    }

    private func loadOperations(agentID: String, version: Int) async {
        guard !demo, scopeIsCurrent, busy == nil else { return }
        do {
            let items = try await network.fetchOperations(agentId: agentID)
            guard version == generation, scopeIsCurrent, selectedAgentID == agentID, busy == nil else { return }
            actionOperations = items; operationsReady = true
        } catch {
            if version == generation, scopeIsCurrent, selectedAgentID == agentID {
                operationsReady = false; self.error = "暂时无法恢复账户操作记录，新的协作操作已暂停。" + error.localizedDescription
            }
        }
    }

    private func actionSubject(_ call: PendingCall) -> String {
        if call.method == .contactsAdd { return "contact" }
        for key in ["approval_id", "request_id", "message_id", "recipient_urn", "action"] {
            if !call.params.string(key).isEmpty { return call.params.string(key) }
        }
        return ""
    }

    func performAction(_ method: RPCMethod, params: RemoteRecord, original: WorkspaceOperation? = nil) async {
        let writes: Set<RPCMethod> = [.contactsAdd, .contactsRespond, .messagesSend, .inboxMarkRead, .approvalRespond, .collaborationExecute]
        guard writes.contains(method), canAct(method), let id = selectedAgentID else { return }
        guard method != .collaborationExecute || params.string("action") != "describe" else { return }
        let call = original?.call ?? PendingCall(method: method, params: params)
        if original == nil, uncertainActions.contains(where: { $0.call.method == method && (method == .collaborationExecute || actionSubject($0.call) == actionSubject(call)) }) {
            error = "同一对象已有结果待核实的操作。请先查看最新状态或核实原请求。"; return
        }
        busy = method.rawValue; error = nil; actionResult = nil; actionResponse = nil
        let version = generation
        var reserved = false
        var phase = "uncertain", message = "原操作已保留，请刷新核实结果。", retryable = true
        do {
            let saved = try await network.reserveOperation(agentId: id, call: call, conversationId: params.string("source_conversation_id").isEmpty ? nil : params.string("source_conversation_id"))
            guard scopeIsCurrent, version == generation, selectedAgentID == id else { busy = nil; return }
            reserved = true
            actionOperations.removeAll { $0.call.requestId == saved.call.requestId }
            actionOperations.insert(saved, at: 0)
            // A terminal ledger fact is authoritative; never submit it again.
            if ["succeeded", "failed"].contains(saved.phase) {
                actionResult = saved.message; busy = nil; return
            }
            let result = try await network.execute(agentId: id, call: call)
            guard scopeIsCurrent, version == generation else { busy = nil; return }
            actionResponse = result
            if result.string("status") == "uncertain" {
                retryable = false; message = result.string("instruction", default: "Agent 尚不能确认是否已执行，请查看事项和消息记录。")
            } else if acceptsAction(call, result: result) {
                phase = "succeeded"; retryable = false
                message = method == .contactsAdd ? "Agent 已受理好友请求；对方接受后才会建立连接。" : "Agent 已确认处理，最新状态正在同步。"
            } else if !result.string("error").isEmpty || ["not_executed", "unsupported", "unavailable", "denied", "rejected"].contains(result.string("status")) {
                phase = "failed"; retryable = false; message = result.string("error", default: "Agent 未执行该操作，请检查授权和当前状态。")
            } else { retryable = false; message = "返回结果不足以确认该操作。原请求已保留，请核实原对象。" }
        } catch let failure as ControlCallError {
            phase = failure.uncertain ? "uncertain" : "failed"; retryable = failure.retryable; message = failure.localizedDescription
        } catch {
            message = reserved ? "提交结果待核实，原请求已保留。" + error.localizedDescription : "无法保存账户操作记录，本次尚未发送控制请求。" + error.localizedDescription
        }
        guard scopeIsCurrent, version == generation else { busy = nil; return }
        if reserved {
            do {
                let saved = try await network.updateOperation(agentId: id, requestId: call.requestId, phase: phase, message: message, retryable: retryable)
                guard scopeIsCurrent, version == generation else { busy = nil; return }
                actionOperations.removeAll { $0.call.requestId == saved.call.requestId }; actionOperations.insert(saved, at: 0)
            } catch { self.error = "原请求已保存在账户中，暂时无法保存最新显示状态，请刷新核实。" }
        }
        actionResult = message
        busy = nil
        if policyAccess { try? await network.scheduleSync(agentId: id) }
        guard scopeIsCurrent, version == generation else { return }
        await readSaved()
        await loadOperations(agentID: id, version: version)
    }

    private func acceptsAction(_ call: PendingCall, result: RemoteRecord) -> Bool {
        let params = call.params, status = result.string("status")
        switch call.method {
        case .contactsAdd: return result.string("decision") == "allow" && ["requested", "request_sent", "pending", "already_requested", "already_connected", "confirmed", "already_confirmed"].contains(status)
        case .contactsRespond: return result.string("request_id") == params.string("request_id") && status == (params.string("decision") == "accept" ? "accepted" : "rejected")
        case .approvalRespond: return result.string("approval_id") == params.string("approval_id") && status == (params.string("decision") == "approve" ? "approved_once" : "denied") && result.string("decision") == (params.string("decision") == "approve" ? "allow" : "deny")
        case .inboxMarkRead: return result.string("message_id") == params.string("message_id") && (status == "read" || result.bool("read"))
        case .messagesSend: return result.string("message_id") == params.string("message_id") && ["sent", "queued", "accepted"].contains(status)
        case .collaborationExecute: return !result.isEmpty && result.string("error").isEmpty && !["not_executed", "unsupported", "unavailable", "denied", "rejected"].contains(status) && result.string("decision") != "deny"
        default: return false
        }
    }

    func retryAction(_ item: WorkspaceOperation) async {
        guard item.retryable, ["sending", "uncertain"].contains(item.phase) else { return }
        await performAction(item.call.method, params: item.call.params, original: item)
    }

    func describeCollaboration() async {
        guard canAct(.collaborationExecute), let id = selectedAgentID else { return }
        busy = "describe"; defer { busy = nil }
        do {
            let result = try await network.execute(agentId: id, call: PendingCall(method: .collaborationExecute, params: ["action": .string("describe")]))
            guard scopeIsCurrent, id == selectedAgentID else { return }
            collaborationDescription = result
        } catch { if scopeIsCurrent { self.error = error.localizedDescription } }
    }

    func confirmApproval(_ approval: RemoteRecord, decision: String) async {
        guard canAct(.approvalRespond), available(.collaborationState), let id = selectedAgentID, ["approve", "deny"].contains(decision), !approval.string("approval_id").isEmpty, !approval.string("question").isEmpty else { return }
        busy = "approval-check"
        do {
            let result = try await network.execute(agentId: id, call: PendingCall(method: .collaborationState))
            guard scopeIsCurrent, id == selectedAgentID else { busy = nil; return }
            guard result.records("pending_confirmations").contains(where: {
                $0.string("approval_id") == approval.string("approval_id") && $0.string("question") == approval.string("question") && $0.string("subject_id") == approval.string("subject_id") && ["pending", "presenting", "expired"].contains($0.string("status"))
            }) else { busy = nil; error = "确认问题已经变化或已处理。请重新读取并查看完整问题。"; await readSaved(); return }
            busy = nil
            await performAction(.approvalRespond, params: ["approval_id": .string(approval.string("approval_id")), "decision": .string(decision)])
        } catch { busy = nil; if scopeIsCurrent { self.error = error.localizedDescription } }
    }

    func refreshNotifications(earlier: Bool = false) async {
        guard !demo, scopeIsCurrent, !loadingNotifications else { return }
        loadingNotifications = true; defer { loadingNotifications = false }
        let filter = notificationFilter
        if loadedNotificationFilter != filter {
            notifications = []; notificationBefore = nil; notificationHistoryLoaded = false; loadedNotificationFilter = filter
        }
        do {
            let page = try await network.fetchNotifications(filter: filter, before: earlier ? notificationBefore : nil)
            guard scopeIsCurrent, filter == notificationFilter else { return }
            let incoming = page.records("items")
            if earlier {
                let keys = Set(notifications.map { $0.string("agentId") + $0.string("id") })
                notifications += incoming.filter { !keys.contains($0.string("agentId") + $0.string("id")) }
                notificationHistoryLoaded = true
            } else if notificationHistoryLoaded {
                let keys = Set(incoming.map { $0.string("agentId") + $0.string("id") })
                notifications = incoming + notifications.filter { !keys.contains($0.string("agentId") + $0.string("id")) }
            } else { notifications = incoming }
            notificationCounts = ["unread": page["unread"] ?? .number(0), "pending": page["pending"] ?? .number(0)]
            if earlier || !notificationHistoryLoaded { notificationBefore = page.bool("hasMore") ? page["before"]?.numberValue : nil }
            notificationError = nil
        } catch { if scopeIsCurrent { notificationError = error.localizedDescription } }
    }

    func openNotification(_ item: RemoteRecord) async {
        guard busy == nil, submission == nil else { return }
        await selectAgent(item.string("agentId"))
        guard selectedAgentID == item.string("agentId") else { return }
        let target = item.record("target")
        if target.string("kind") == "conversation" { await navigateToConversation(id: target.string("id"), turnID: target.string("turn_id")) }
        else { collaborationFocusID = target.string("id"); tab = 2 }
    }

    func markNotificationRead(_ item: RemoteRecord) async {
        guard !demo, scopeIsCurrent, busy == nil else { return }
        guard let revision = Int(exactly: item.number("revision")), revision > 0, revision <= 9_007_199_254_740_991 else { notificationError = "提醒版本无效，请刷新后重试。"; return }
        let target = item.record("target")
        if target.string("kind") == "inbox" && item.string("state") == "open" {
            await selectAgent(item.string("agentId"))
            guard canAct(.inboxMarkRead), workspace?.sync.status != "offline" else { error = "Agent 已读同步尚未开放或暂不可用，请检查当前连接和授权。"; return }
            await performAction(.inboxMarkRead, params: ["message_id": .string(target.string("id"))])
            guard actionOperations.contains(where: { $0.call.method == .inboxMarkRead && $0.call.params.string("message_id") == target.string("id") && $0.phase == "succeeded" }) else { return }
        }
        do {
            try await network.markNotificationRead(agentId: item.string("agentId"), id: item.string("id"), revision: revision)
            guard scopeIsCurrent else { return }
            for index in notifications.indices where notifications[index].string("agentId") == item.string("agentId") && notifications[index].string("id") == item.string("id") && notifications[index].number("revision") == Double(revision) { notifications[index]["unread"] = false }
            if notificationFilter == "unread" { notifications.removeAll { !$0.bool("unread") } }
            await refreshNotifications()
        } catch { if scopeIsCurrent { notificationError = error.localizedDescription } }
    }

    func navigateToConversation(id: String, turnID: String? = nil) async {
        await selectConversation(id)
        if conversationID != id && policyAccess { await openConversation(id) }
        if conversationID == id { focusTurnID = turnID; tab = 1 }
    }

    func manageConnection(name: String? = nil, remove: Bool = false) async {
        guard !demo, scopeIsCurrent, busy == nil, let id = selectedAgentID else { return }
        busy = "connection"; error = nil
        do {
            if remove { try await network.removeConnection(agentId: id) }
            else if let name { try await network.renameConnection(agentId: id, name: name) }
            guard scopeIsCurrent else { busy = nil; return }
            busy = nil
            if remove { generation += 1; selectedAgentID = nil; workspace = nil; cache[id] = nil; submission = nil; draft = ""; localRecoveryReady = false; actionOperations = []; operationsReady = false }
            await refresh()
        } catch { busy = nil; if scopeIsCurrent { self.error = error.localizedDescription } }
    }

    func setRecordHidden(kind: String, id: String, hidden: Bool) async {
        guard !demo, scopeIsCurrent, busy == nil, let agentID = selectedAgentID else { return }
        busy = "record"; defer { busy = nil }
        do { _ = try await network.saveRecordState(agentId: agentID, kind: kind, id: id, deleted: hidden); guard scopeIsCurrent else { return }; await readSaved() }
        catch { if scopeIsCurrent { self.error = error.localizedDescription } }
    }
}
