import Foundation

public extension PendingCall {
    /// Deterministic transport bytes, including when a call was restored from another client.
    /// Older Web backends fingerprint JSON.stringify(params), so send's known keys must
    /// follow the Web client's text/conversation_id order until those backends are updated.
    func encodeRequestBody() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        func encoded<T: Encodable>(_ value: T) throws -> String {
            String(decoding: try encoder.encode(value), as: UTF8.self)
        }

        let preferred = method == .conversationSend ? ["text", "conversation_id"] : []
        let keys = preferred.filter { params[$0] != nil } + params.keys.filter { !preferred.contains($0) }.sorted()
        let entries = try keys.map { key in
            try encoded(key) + ":" + encoded(params[key]!)
        }.joined(separator: ",")
        let body = try "{\"request_id\":" + encoded(requestId) + ",\"method\":" + encoded(method.rawValue) + ",\"params\":{" + entries + "}}"
        return Data(body.utf8)
    }
}
