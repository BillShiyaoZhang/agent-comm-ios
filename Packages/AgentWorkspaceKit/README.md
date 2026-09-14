# AgentWorkspaceKit

A Foundation-based Swift package for the current `agent-collaboration-web` workspace API. The package has no SwiftUI/Combine dependency and can be consumed by iOS, macOS, visionOS or another Swift client. The app's `NetworkManager` only owns observable session state.

```swift
import AgentWorkspaceKit

let client = try WorkspaceClient(server: "https://agent-communication.online")
let user = try await client.login(email: email, password: password)
let overview = try await client.fetchOverview()
let workspace = try await client.fetchWorkspace(agentId: overview.connections[0].id)
```

## Supported contracts

- NextAuth CSRF, credentials callback, session, registration and sign-out.
- Workspace overview, saved connection creation, console identity binding, conversation selection, pagination, background sync scheduling and uncertain-submission dismissal.
- The six `agent-comm-control/v1` methods: capabilities, contacts, collaboration state, inbox, conversation send/get.
- Codable workspace models, flexible `JSONValue` remote records, monotonic turn/snapshot merging and pairing expiry rules.

`fetchWorkspace(conversationId: nil)` resumes the saved active conversation. An empty string explicitly requests a new conversation; a nonempty ID requests that conversation. This distinction matches the deployed API.

## Session and trust boundary

This client talks over HTTPS to the Web backend using an isolated NextAuth cookie jar. It does not hold the agent's encryption keys or directly implement the platform's signed/encrypted transport: the Web backend verifies and decrypts agent responses. Each mutation sends the configured backend origin, which must agree with that deployment's `NEXTAUTH_URL` origin. The Swift client additionally correlates request IDs, method, protocol, response type and exactly one result/error. API redirects are rejected.

Apple platforms persist cookies in device-only Keychain entries scoped to the canonical server origin. Cookie Secure, HttpOnly and expiry attributes survive restoration. `SecureStore` uses memory only where Security.framework is unavailable; a non-Apple app must supply its own durable secret storage if persistence is needed. Passwords are never saved. Changing or clearing a session invalidates in-flight multi-request operations. The iOS facade removes legacy UserDefaults cookie data.

Public servers require HTTPS. HTTP is accepted only for localhost, `.local` names and private/link-local IP addresses. The consuming app must also configure platform transport entitlements/ATS rules for any intended LAN access.

## Safe control retries

Create and durably save a `PendingCall` **before** submitting a write. On a timeout, cancellation or `ControlCallError.uncertain`, keep that same request ID and parameters for reconciliation/retry; never silently make a fresh ID. The package performs at most 65 polling reads, with a 150-second overall limit and at most 30 seconds per HTTP request. Cancellation stops polling. A correlated remote error is a confirmed rejection; an HTTP failure, malformed response or expired request cannot establish whether a send already happened.

The app owns its account/server-scoped durable submission journal and conversation drafts. The package does not choose a UI policy for discarding uncertain work.

`PendingCall.encodeRequestBody()` produces deterministic transport JSON after dictionary reconstruction or journal decoding. Conversation sends serialize `text` before `conversation_id`, matching the existing Web client and older deployed backends whose request fingerprints depend on parameter key order. Additional keys and nested objects use stable sorted serialization. The client uses this serializer for every control submission.

## Verification and shared fixtures

Run `swift test --package-path Packages/AgentWorkspaceKit` from the repository root. On a restricted macOS build host:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/agent-workspace-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/agent-workspace-module-cache \
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
swift test --disable-sandbox --package-path Packages/AgentWorkspaceKit \
  --scratch-path /tmp/agent-workspace-swift-build
```

Tests use URLProtocol stubs and public fixture data; they never register, log in or send messages to a live account. Test fixtures are copied from the canonical sibling deploy project:

`agent-collaboration-web/packages/client-contract/fixtures/*.json`

Refresh those copies when the shared contract changes. They verify multilingual payloads, null handling, unknown capabilities, workspace millisecond timestamps, remote second/millisecond expiry compatibility, and exact request correlation across Web and Swift clients.
