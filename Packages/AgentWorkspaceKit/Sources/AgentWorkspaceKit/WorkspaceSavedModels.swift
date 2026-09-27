import Foundation

public struct WorkspaceNotificationCounts: Codable, Sendable, Hashable {
    public var unread: Int
    public var pending: Int
    public init(unread: Int = 0, pending: Int = 0) { self.unread = unread; self.pending = pending }
}

/// Only server-authenticated responses and snapshots can settle an operation.
public struct WorkspaceOperation: Codable, Sendable, Hashable, Identifiable {
    public var id: String { call.requestId }
    public var call: PendingCall
    public var phase: String
    public var message: String
    public var retryable: Bool
    public var result: RemoteRecord?
    public var reusedContact: Bool?
    public var conversationId: String?
    public var createdAt: Double
    public var updatedAt: Double
    public init(call: PendingCall, phase: String = "sending", message: String = "正在提交，等待 agent 确认…", retryable: Bool = true,
                result: RemoteRecord? = nil, reusedContact: Bool? = nil, conversationId: String? = nil, createdAt: Double = 0, updatedAt: Double = 0) {
        self.call = call; self.phase = phase; self.message = message; self.retryable = retryable; self.result = result
        self.reusedContact = reusedContact; self.conversationId = conversationId; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
    public var unresolved: Bool { ["sending", "uncertain"].contains(phase) }
}

public struct WorkspaceConversationState: Codable, Sendable, Hashable {
    public var title: String?
    public var archived: Bool
    public var deleted: Bool?
    public var readAt: Double
    public var draft: String
    public var scrollTop: Double?
    public init(title: String? = nil, archived: Bool = false, deleted: Bool? = nil, readAt: Double = 0, draft: String = "", scrollTop: Double? = nil) {
        self.title = title; self.archived = archived; self.deleted = deleted; self.readAt = readAt; self.draft = draft; self.scrollTop = scrollTop
    }
}

public struct WorkspaceRecordState: Codable, Sendable, Hashable, Identifiable {
    public var kind: String
    public var id: String
    public var deleted: Bool
    public var updatedAt: Double
    public var title: String?
    public var relatedIds: [String]?
    public init(kind: String, id: String, deleted: Bool, updatedAt: Double = 0, title: String? = nil, relatedIds: [String]? = nil) {
        self.kind = kind; self.id = id; self.deleted = deleted; self.updatedAt = updatedAt; self.title = title; self.relatedIds = relatedIds
    }
}

public func availableMethods(capabilities: RemoteRecord?) -> [RPCMethod] {
    (capabilities?.records("methods") ?? []).compactMap { item in
        item.bool("available") ? RPCMethod(rawValue: item.string("name")) : nil
    }
}

/// Agent-provided provenance is navigation context, never an authorization claim.
public func sourceConversation(_ record: RemoteRecord) -> (conversationId: String, turnId: String?)? {
    let context = record.record("source_context"), id = context.string("conversation_id")
    guard ["paired_conversation", "paired_control"].contains(context.string("origin")), isStableID(id) else { return nil }
    let turnId = context.string("turn_id")
    return (id, isStableID(turnId) ? turnId : nil)
}

public func isStableID(_ value: String) -> Bool {
    value.range(of: "^[A-Za-z0-9._:-]{1,128}$", options: .regularExpression) != nil
}

public func attentionRequiresAction(kind: String, state: String) -> Bool {
    state == "open" && ["owner_decision_required", "needs_recovery", "connection_action_required", "needs_response", "new_collaboration_request", "friend_request_received"].contains(kind)
}

/// Validate an attention page before saving or advancing its durable cursor.
/// Remote records preserve new optional fields from the agent.
public func validateAttentionPage(_ page: RemoteRecord) throws -> RemoteRecord {
    func stable(_ value: JSONValue?) -> Bool { value?.stringValue.map { !$0.isEmpty && $0.utf16.count <= 512 } ?? false }
    func safeInteger(_ value: JSONValue?, minimum: Double = 0) -> Bool {
        guard let number = value?.numberValue else { return false }
        return number.isFinite && number >= minimum && number <= 9_007_199_254_740_991 && number.rounded(.towardZero) == number
    }
    func time(_ value: JSONValue?) -> Bool { value?.numberValue.map { $0.isFinite && $0 >= 0 } ?? false }
    guard page.string("schema") == "agent-comm-attention/v1", let rawItems = page["items"]?.arrayValue, rawItems.count <= 100,
          safeInteger(page["cursor"]), page["has_more"]?.boolValue != nil else { throw WorkspaceClientError.invalidResponse }
    var ids: Set<String> = []
    for raw in rawItems {
        guard let item = raw.objectValue else { throw WorkspaceClientError.invalidResponse }
        let target = item.record("target"), turn = target["turn_id"]
        let source = item["source_revision"]
        guard stable(item["attention_id"]), ids.insert(item.string("attention_id")).inserted, stable(item["kind"]), stable(item["subject_id"]),
              safeInteger(item["revision"], minimum: 1), item.number("revision") <= page.number("cursor"), source?.stringValue != nil || safeInteger(source, minimum: -9_007_199_254_740_991),
              ["open", "resolved", "superseded", "expired"].contains(item.string("state")),
              item["title"]?.stringValue.map({ $0.utf16.count <= 1000 }) == true, item["safe_summary"]?.stringValue.map({ $0.utf16.count <= 8000 }) == true,
              ["task", "inbox", "approval", "contact", "conversation"].contains(target.string("kind")), stable(target["id"]),
              target.string("kind") != "conversation" || isStableID(target.string("id")) && isStableID(target.string("turn_id")),
              turn == nil || turn == .null || isStableID(target.string("turn_id")),
              time(item["created_at"]), time(item["updated_at"]), item["expires_at"] == nil || item["expires_at"] == .null || time(item["expires_at"]) else {
            throw WorkspaceClientError.invalidResponse
        }
    }
    return page
}
