import Foundation

public enum RPCMethod: String, Codable, CaseIterable, Sendable, Hashable {
    case capabilities
    case contactsList = "contacts.list"
    case collaborationState = "collaboration.state"
    case inboxList = "inbox.list"
    case conversationSend = "conversation.send"
    case conversationGet = "conversation.get"
}

public struct PendingCall: Codable, Sendable, Hashable {
    public var requestId: String
    public var method: RPCMethod
    public var params: RemoteRecord
    enum CodingKeys: String, CodingKey { case requestId = "request_id", method, params }
    public init(requestId: String = UUID().uuidString.lowercased(), method: RPCMethod, params: RemoteRecord = [:]) {
        self.requestId = requestId; self.method = method; self.params = params
    }
}

public struct SessionUser: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var email: String
    public var name: String?
    public init(id: String, email: String, name: String? = nil) { self.id = id; self.email = email; self.name = name }
}

public struct WorkspaceSync: Codable, Sendable, Hashable {
    public var status: String
    public var lastAttemptAt: Double?
    public var lastSuccessAt: Double?
    public var nextSyncAt: Double?
    public var error: String?
    public init(status: String = "waiting", lastAttemptAt: Double? = nil, lastSuccessAt: Double? = nil, nextSyncAt: Double? = nil, error: String? = nil) {
        self.status = status; self.lastAttemptAt = lastAttemptAt; self.lastSuccessAt = lastSuccessAt; self.nextSyncAt = nextSyncAt; self.error = error
    }
}

public struct WorkspaceConnection: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var urn: String
    public var platformRegistered: Bool
    public var lastActiveAt: String?
    public var createdAt: String
    public var sync: WorkspaceSync
    public init(id: String, name: String, urn: String, platformRegistered: Bool = true, lastActiveAt: String? = nil, createdAt: String = "", sync: WorkspaceSync = .init()) {
        self.id = id; self.name = name; self.urn = urn; self.platformRegistered = platformRegistered; self.lastActiveAt = lastActiveAt; self.createdAt = createdAt; self.sync = sync
    }
}

public struct WorkspaceIdentity: Codable, Sendable, Hashable {
    public var virtualUrn: String?
    public var virtualEd25519PublicKey: String?
    public var virtualX25519PublicKey: String?
    public init(virtualUrn: String? = nil, virtualEd25519PublicKey: String? = nil, virtualX25519PublicKey: String? = nil) {
        self.virtualUrn = virtualUrn; self.virtualEd25519PublicKey = virtualEd25519PublicKey; self.virtualX25519PublicKey = virtualX25519PublicKey
    }
}

public struct WorkspaceSnapshot: Codable, Sendable, Hashable {
    public var data: RemoteRecord
    public var time: Double
    public var requestId: String?
    public init(data: RemoteRecord, time: Double, requestId: String? = nil) { self.data = data; self.time = time; self.requestId = requestId }
}

public struct WorkspaceConversation: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var updatedAt: Double
    public var pending: Bool
    public var turnCount: Int
    public init(id: String, title: String, updatedAt: Double = 0, pending: Bool = false, turnCount: Int = 0) {
        self.id = id; self.title = title; self.updatedAt = updatedAt; self.pending = pending; self.turnCount = turnCount
    }
}

public struct WorkspaceSubmission: Codable, Sendable, Hashable {
    public var call: PendingCall
    public var text: String
    public var conversationId: String
    public var turnId: String
    public var phase: String
    public var retryable: Bool
    public init(call: PendingCall, text: String, conversationId: String, turnId: String, phase: String = "sending", retryable: Bool = true) {
        self.call = call; self.text = text; self.conversationId = conversationId; self.turnId = turnId; self.phase = phase; self.retryable = retryable
    }
}

public struct WorkspaceAgent: Codable, Sendable, Hashable {
    public var agent: WorkspaceConnection
    public var identity: WorkspaceIdentity
    public var sync: WorkspaceSync
    public var snapshots: [String: WorkspaceSnapshot]
    public var conversations: [WorkspaceConversation]
    public var activeConversationId: String
    public var conversation: RemoteRecord?
    public var hasEarlierTurns: Bool
    public var submission: WorkspaceSubmission?
    public init(agent: WorkspaceConnection, identity: WorkspaceIdentity = .init(), sync: WorkspaceSync = .init(), snapshots: [String: WorkspaceSnapshot] = [:], conversations: [WorkspaceConversation] = [], activeConversationId: String = "", conversation: RemoteRecord? = nil, hasEarlierTurns: Bool = false, submission: WorkspaceSubmission? = nil) {
        self.agent = agent; self.identity = identity; self.sync = sync; self.snapshots = snapshots; self.conversations = conversations; self.activeConversationId = activeConversationId; self.conversation = conversation; self.hasEarlierTurns = hasEarlierTurns; self.submission = submission
    }
}

public struct WorkspaceOverview: Codable, Sendable, Hashable {
    public var connections: [WorkspaceConnection]
    public init(connections: [WorkspaceConnection]) { self.connections = connections }
}

/// Delayed snapshots cannot overwrite a newer saved result.
public func mergeSnapshots(previous: [String: WorkspaceSnapshot], incoming: [String: WorkspaceSnapshot]) -> [String: WorkspaceSnapshot] {
    var merged = previous
    for (key, snapshot) in incoming where snapshot.time >= (merged[key]?.time ?? -.infinity) { merged[key] = snapshot }
    return merged
}

/// A delayed cache read cannot make a completed turn pending again.
public func mergeTurns(earlier: [RemoteRecord], latest: [RemoteRecord]) -> [RemoteRecord] {
    var byId: [String: RemoteRecord] = [:]
    for turn in earlier + latest {
        let id = turn.string("turn_id")
        guard !id.isEmpty else { continue }
        if let saved = byId[id] {
            let terminal = ["completed", "failed"].contains(saved.string("status")) || saved.string("status") == "interrupted" && !saved.bool("locally_unconfirmed")
            if terminal && ["submitted", "running"].contains(turn.string("status")) { continue }
        }
        byId[id] = turn
    }
    return byId.values.sorted { left, right in
        if left.number("created_at") != right.number("created_at") { return left.number("created_at") < right.number("created_at") }
        return left.string("turn_id") < right.string("turn_id")
    }
}

public func pairingAllowsSend(capabilities: RemoteRecord?, sync: WorkspaceSync, now: Date = Date()) -> Bool {
    guard sync.status != "needs_pairing" else { return false }
    guard let expiry = capabilities?.record("pairing")["expires_at"], expiry != .null else { return true }
    if let value = expiry.numberValue {
        let seconds = value < 1_000_000_000_000 ? value : value / 1000
        return seconds.isFinite && seconds > now.timeIntervalSince1970
    }
    guard let raw = expiry.stringValue else { return false }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let fractional = formatter.date(from: raw)
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = fractional ?? formatter.date(from: raw) else { return false }
    return date > now
}
