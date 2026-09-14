import XCTest
@testable import AgentWorkspaceKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class WorkspaceClientTests: XCTestCase {
    private let requestId = "00000000-0000-4000-8000-000000000001"

    override func tearDown() {
        StubProtocol.reset()
        super.tearDown()
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func client(polls: Int = 2, interval: UInt64 = 1_000_000) throws -> WorkspaceClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return try WorkspaceClient(server: "https://workspace.example", configuration: config, persistSession: false, pollingInterval: interval, maximumPolls: polls)
    }

    func testCanonicalWorkspaceFixturesDecodeAndPreserveUnknownFields() throws {
        let decoder = JSONDecoder()
        let agent = try decoder.decode(WorkspaceAgent.self, from: fixture("workspace-agent"))
        let overview = try decoder.decode(WorkspaceOverview.self, from: fixture("workspace-overview"))
        XCTAssertEqual(agent.agent.name, "工作助理")
        XCTAssertEqual(overview.connections.first?.id, agent.agent.id)
        XCTAssertEqual(agent.submission?.call.requestId, requestId)
        XCTAssertEqual(agent.submission?.phase, "uncertain")
        XCTAssertEqual(agent.conversation?.records("turns").count, 2)
        XCTAssertEqual(agent.snapshots["capabilities"]?.data.records("methods").last?.string("name"), "approval.respond")
        XCTAssertEqual(try decoder.decode(WorkspaceAgent.self, from: JSONEncoder().encode(agent)), agent)
        let call = try decoder.decode(PendingCall.self, from: fixture("control-send"))
        XCTAssertEqual(call.method, .conversationSend)
        XCTAssertEqual(call.params.string("text"), "请整理今天的协作进展。")
    }

    func testServerValidationRejectsCredentialLeaksAndPublicHTTP() throws {
        for value in ["http://example.com", "https://user:password@example.com", "https://example.com/path", "https://example.com?token=secret", "file:///tmp/x", "http://172.32.0.1", "http://127.0.0.1.evil.example", "http://0127.0.0.1"] {
            XCTAssertThrowsError(try WorkspaceClient.validateServer(value), value)
        }
        for value in ["https://example.com", "http://localhost:3000", "http://192.168.2.4:3000", "http://172.16.0.2", "http://10.0.0.2", "http://[::1]:3000", "http://computer.local:3000"] {
            XCTAssertNoThrow(try WorkspaceClient.validateServer(value), value)
        }
        XCTAssertEqual(try WorkspaceClient.validateServer(" example.com/ ").absoluteString, "https://example.com")
        XCTAssertEqual(try WorkspaceClient.validateServer("https://EXAMPLE.com:443/").absoluteString, "https://example.com")
    }

    func testLoginEncodesReservedCredentialsAndKeepsPrivateCookieJar() async throws {
        StubProtocol.respond { request in
            switch request.url?.path {
            case "/api/auth/csrf":
                return (200, ["Set-Cookie": "next-auth.csrf-token=token; Path=/; HttpOnly; Secure"], Data("{\"csrfToken\":\"a+b&c=中\"}".utf8))
            case "/api/auth/callback/credentials":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://workspace.example")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "next-auth.csrf-token=token")
                let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                XCTAssertTrue(body.contains("email=a%2Bb%40example.com"), body)
                XCTAssertTrue(body.contains("password=%26%3D%2B%25%20%E4%B8%AD"), body)
                XCTAssertTrue(body.contains("csrfToken=a%2Bb%26c%3D%E4%B8%AD"), body)
                return (200, ["Set-Cookie": "next-auth.session-token=secret; Path=/; HttpOnly; Secure"], Data("{\"url\":\"https://workspace.example\"}".utf8))
            case "/api/auth/session":
                XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("next-auth.session-token=secret") == true)
                return (200, [:], Data("{\"user\":{\"id\":\"user-a\",\"email\":\"a+b@example.com\"}}".utf8))
            default: throw URLError(.badURL)
            }
        }
        let api = try client()
        let user = try await api.login(email: "a+b@example.com", password: "&=+% 中")
        XCTAssertEqual(user.id, "user-a")
        XCTAssertEqual(StubProtocol.requests.count, 3)
        XCTAssertFalse(HTTPCookieStorage.shared.cookies?.contains { $0.value == "secret" && $0.domain == "workspace.example" } == true)
    }

    func testEmptySessionAndFailedLogoutClearCookies() async throws {
        StubProtocol.respond { request in
            if request.url?.path == "/api/auth/csrf" { return (503, [:], Data("{\"error\":\"offline\"}".utf8)) }
            return (200, [:], Data("{ \n }".utf8))
        }
        let api = try client()
        let user = try await api.checkSession()
        XCTAssertNil(user)
        do { try await api.logout(); XCTFail("Logout should report server failure") } catch { XCTAssertEqual(error.localizedDescription, "offline") }
        let restoredUser = try await api.checkSession()
        XCTAssertNil(restoredUser)
    }

    func testWorkspaceMutationsUseOriginAndExactRoutes() async throws {
        let workspace = try fixture("workspace-agent")
        StubProtocol.respond { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://workspace.example")
            XCTAssertEqual(request.httpMethod, "POST")
            return (200, [:], workspace)
        }
        let api = try client()
        _ = try await api.selectConversation(agentId: "agent-a", conversationId: nil)
        _ = try await api.dismissSubmission(agentId: "agent-a", requestId: requestId)
        let requests = StubProtocol.requests
        XCTAssertTrue(requests.allSatisfy { $0.url?.path == "/api/agents/agent-a/workspace" })
        let body = try JSONDecoder().decode(RemoteRecord.self, from: XCTUnwrap(requests.first?.httpBody))
        XCTAssertEqual(body["conversationId"], .null)
        XCTAssertEqual(body.string("action"), "select_conversation")
    }

    func testWorkspaceQueryDistinguishesResumedNewAndNamedConversations() async throws {
        let workspace = try fixture("workspace-agent")
        StubProtocol.respond { _ in (200, [:], workspace) }
        let api = try client()
        _ = try await api.fetchWorkspace(agentId: "agent-a")
        _ = try await api.fetchWorkspace(agentId: "agent-a", conversationId: "")
        _ = try await api.fetchWorkspace(agentId: "agent-a", conversationId: "chat-1", before: "turn-1")
        let queries = StubProtocol.requests.map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems }
        XCTAssertNil(queries[0])
        XCTAssertEqual(queries[1]?.first?.name, "conversation_id")
        XCTAssertEqual(queries[1]?.first?.value, "")
        XCTAssertEqual(queries[2], [URLQueryItem(name: "conversation_id", value: "chat-1"), URLQueryItem(name: "before", value: "turn-1")])
    }

    func testControlPollsSameRequestAndValidatesEnvelope() async throws {
        let pending = try fixture("control-pending"), complete = try fixture("control-complete")
        StubProtocol.respond { request in
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://workspace.example")
                XCTAssertEqual(String(data: request.httpBody ?? Data(), encoding: .utf8), "{\"request_id\":\"\(self.requestId)\",\"method\":\"conversation.send\",\"params\":{\"text\":\"你好\",\"conversation_id\":\"chat-1\"}}")
                return (202, [:], pending)
            }
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, self.requestId)
            return (200, [:], complete)
        }
        let call = PendingCall(requestId: requestId, method: .conversationSend, params: ["text": "你好", "conversation_id": "chat-1"])
        let result = try await client().execute(agentId: "agent-a", call: call)
        XCTAssertEqual(result.string("turn_id"), "turn-2")
        XCTAssertEqual(StubProtocol.requests.count, 2)
    }

    func testSendWireEncodingMatchesLegacyWebOrderAfterJournalRestoration() throws {
        let original = try JSONDecoder().decode(PendingCall.self, from: fixture("control-send"))
        var reversed: RemoteRecord = [:]
        reversed["conversation_id"] = original.params["conversation_id"]
        reversed["text"] = original.params["text"]
        let reconstructed = PendingCall(requestId: original.requestId, method: original.method, params: reversed)
        let journal = try JSONDecoder().decode(PendingCall.self, from: JSONEncoder().encode(reconstructed))
        let expected = "{\"request_id\":\"\(requestId)\",\"method\":\"conversation.send\",\"params\":{\"text\":\"请整理今天的协作进展。\",\"conversation_id\":\"chat-1\"}}"
        for call in [original, reconstructed, journal] {
            let body = try call.encodeRequestBody()
            XCTAssertEqual(String(decoding: body, as: UTF8.self), expected)
            XCTAssertEqual(try JSONDecoder().decode(PendingCall.self, from: body), original)
        }
    }

    func testControlWireEncodingSortsUnknownNestedParamsAndEscapesStrings() throws {
        let text = "引号\"、反斜线\\、换行\n以及 / 路径"
        let left = PendingCall(requestId: requestId, method: .conversationSend, params: [
            "z": .object(["b": 2, "a": 1]), "conversation_id": "chat-1", "text": .string(text), "a": [true, nil]
        ])
        let right = PendingCall(requestId: requestId, method: .conversationSend, params: [
            "text": .string(text), "a": [true, nil], "z": .object(["a": 1, "b": 2]), "conversation_id": "chat-1"
        ])
        let first = try left.encodeRequestBody()
        XCTAssertEqual(first, try right.encodeRequestBody())
        XCTAssertEqual(try JSONDecoder().decode(PendingCall.self, from: first), left)
        XCTAssertTrue(String(decoding: first, as: UTF8.self).hasSuffix("\"conversation_id\":\"chat-1\",\"a\":[true,null],\"z\":{\"a\":1,\"b\":2}}}"))
    }

    func testMismatchedOrMalformedResultsRemainUncertain() async throws {
        var body = try JSONDecoder().decode(RemoteRecord.self, from: fixture("control-complete"))
        var response = body.record("response")
        response["request_id"] = "00000000-0000-4000-8000-000000000002"
        body["response"] = .object(response)
        let mismatch = try JSONEncoder().encode(body)
        StubProtocol.respond { _ in (200, [:], mismatch) }
        let call = PendingCall(requestId: requestId, method: .conversationSend)
        do { _ = try await client().execute(agentId: "agent-a", call: call); XCTFail("Mismatched ID accepted") }
        catch let error as ControlCallError {
            XCTAssertTrue(error.uncertain)
            XCTAssertTrue(error.retryable)
            XCTAssertEqual(error.call.requestId, call.requestId)
        }
    }

    func testBoundedPendingAndRetryPreservesWriteID() async throws {
        let pending = try fixture("control-pending")
        StubProtocol.respond { _ in (202, [:], pending) }
        let api = try client(polls: 1)
        let call = PendingCall(requestId: requestId, method: .conversationSend)
        for _ in 0..<2 {
            do { _ = try await api.execute(agentId: "agent-a", call: call); XCTFail("Pending request completed") }
            catch let error as ControlCallError { XCTAssertTrue(error.uncertain); XCTAssertEqual(error.call, call) }
        }
        XCTAssertEqual(StubProtocol.requests.count, 4)
        let posts = try StubProtocol.requests.filter { $0.httpMethod == "POST" }.map { try JSONDecoder().decode(PendingCall.self, from: XCTUnwrap($0.httpBody)) }
        XCTAssertEqual(posts.map(\.requestId), [requestId, requestId])
    }

    func testRemoteRejectionIsConfirmedAndNonretryable() async throws {
        let rejected = try fixture("control-pairing-error")
        StubProtocol.respond { _ in (200, [:], rejected) }
        do { _ = try await client().execute(agentId: "agent-a", call: PendingCall(requestId: requestId, method: .conversationSend)); XCTFail("Remote rejection accepted") }
        catch let error as ControlCallError { XCTAssertFalse(error.uncertain); XCTAssertFalse(error.retryable) }
    }

    func testUnauthorizedSendRemainsUncertainAndExposesSessionStatus() async throws {
        StubProtocol.respond { _ in (401, [:], Data("{\"error\":\"Unauthorized\"}".utf8)) }
        do { _ = try await client().execute(agentId: "agent-a", call: PendingCall(requestId: requestId, method: .conversationSend)); XCTFail("Unauthorized accepted") }
        catch let error as ControlCallError { XCTAssertEqual(error.httpStatus, 401); XCTAssertTrue(error.uncertain); XCTAssertFalse(error.retryable) }
    }

    func testCancellationStopsPollingPromptly() async throws {
        let pending = try fixture("control-pending")
        StubProtocol.respond { _ in (202, [:], pending) }
        let api = try client(polls: 65, interval: 10_000_000_000)
        let call = PendingCall(requestId: requestId, method: .conversationSend)
        let task = Task { try await api.execute(agentId: "agent-a", call: call) }
        for _ in 0..<100 {
            if !StubProtocol.requests.isEmpty { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let start = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation ignored") } catch is CancellationError { }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertEqual(StubProtocol.requests.count, 1)
    }

    func testClearingSessionPreventsOldControlPollsUnderNewSession() async throws {
        let pending = try fixture("control-pending")
        StubProtocol.respond { _ in (202, [:], pending) }
        let api = try client(polls: 65, interval: 50_000_000)
        let call = PendingCall(requestId: requestId, method: .conversationSend)
        let task = Task { try await api.execute(agentId: "agent-a", call: call) }
        for _ in 0..<100 {
            if !StubProtocol.requests.isEmpty { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try await api.clearSession()
        do { _ = try await task.value; XCTFail("Old session continued polling") } catch is CancellationError { }
        XCTAssertEqual(StubProtocol.requests.count, 1)
    }

    func testMergeAvoidsSnapshotAndTurnRegression() {
        let saved: RemoteRecord = ["turn_id": "one", "status": "completed", "created_at": 2, "response": "done"]
        let stale: RemoteRecord = ["turn_id": "one", "status": "running", "created_at": 2]
        let earlier: RemoteRecord = ["turn_id": "zero", "status": "completed", "created_at": 1]
        XCTAssertEqual(mergeTurns(earlier: [saved], latest: [stale, earlier]), [earlier, saved])
        let snapshot = WorkspaceSnapshot(data: ["value": "new"], time: 200)
        XCTAssertEqual(mergeSnapshots(previous: ["capabilities": snapshot], incoming: ["capabilities": .init(data: ["value": "old"], time: 100)])["capabilities"], snapshot)
    }

    func testPairingExpiryIsExplicitAndRequiresValidFutureTime() {
        let now = Date(timeIntervalSince1970: 1_789_372_800)
        XCTAssertTrue(pairingAllowsSend(capabilities: nil, sync: .init(status: "ready"), now: now))
        XCTAssertFalse(pairingAllowsSend(capabilities: nil, sync: .init(status: "needs_pairing"), now: now))
        XCTAssertFalse(pairingAllowsSend(capabilities: ["pairing": ["expires_at": "invalid"]], sync: .init(status: "ready"), now: now))
        XCTAssertFalse(pairingAllowsSend(capabilities: ["pairing": ["expires_at": 1_789_372_800]], sync: .init(status: "ready"), now: now))
        XCTAssertTrue(pairingAllowsSend(capabilities: ["pairing": ["expires_at": "2026-09-15T08:00:00.000Z"]], sync: .init(status: "ready"), now: now))
    }

    func testCanonicalPairingPolicyVectors() throws {
        let cases = try JSONDecoder().decode(RemoteRecord.self, from: fixture("policy-cases"))
        for vector in cases.records("pairing") {
            let actual = pairingAllowsSend(capabilities: ["pairing": .object(["expires_at": vector["expiresAt"] ?? .null])], sync: .init(status: "ready"), now: Date(timeIntervalSince1970: vector.number("now") / 1000))
            XCTAssertEqual(actual, vector.bool("allowed"), "\(vector)")
        }
    }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    typealias Reply = (Int, [String: String], Data)
    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> Reply)?
    private static var captured: [URLRequest] = []
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    static func respond(_ handler: @escaping (URLRequest) throws -> Reply) { lock.lock(); defer { lock.unlock() }; Self.handler = handler; captured = [] }
    static func reset() { lock.lock(); defer { lock.unlock() }; handler = nil; captured = [] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            request.httpBody = data
        }
        Self.lock.lock()
        Self.captured.append(request)
        let handler = Self.handler
        Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.resourceUnavailable) }
            let (status, headers, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
