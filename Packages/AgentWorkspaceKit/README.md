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

- NextAuth CSRF, credentials callback, session, registration and sign-out; account status, verification email, password reset and password change requests.
- Workspace overview, saved connection creation, console identity binding, conversation selection, pagination, background sync scheduling and uncertain-submission dismissal.
- All 14 current `agent-comm-control/v1` methods, including attention, contact requests, direct messages, inbox read state, approval responses and collaboration actions.
- Platform policy disclosure/confirmation/pause/resume, revision-aware in-app notifications, durable operation reservations, saved conversation search/state, account record hiding/restoration and connection management.
- One-time agent connection authorization preview/approval, saved account activity, Codable workspace models, flexible `JSONValue` remote records, monotonic turn/snapshot merging and pairing/policy rules.

Registration returns an accepted response and sends an email verification link; it does not establish a signed-in session. New accounts must verify before credentials login. `WorkspaceClientError.emailNotVerified` distinguishes this requirement from an incorrect password. `resendVerification` and `requestPasswordReset` preserve the server's neutral response to avoid exposing whether an account exists. Email links complete verification/password recovery on the Web service.

`fetchWorkspace(conversationId: nil)` resumes the saved active conversation. An empty string explicitly requests a new conversation; a nonempty ID requests that conversation. This distinction is part of the workspace API contract. Check the [backend compatibility requirements](../../docs/DEVELOPMENT.md#服务端版本与兼容检查) against the server version you deploy.

## Session and trust boundary

This client talks over HTTPS to the Web backend using an isolated NextAuth cookie jar. It does not hold the agent's encryption keys or directly implement the platform's signed/encrypted transport: the Web backend verifies and decrypts agent responses. Each mutation sends the configured backend origin, which must agree with that deployment's `NEXTAUTH_URL` origin. The Swift client additionally correlates request IDs, method, protocol, response type and exactly one result/error. API redirects are rejected.

Apple platforms persist cookies in device-only Keychain entries scoped to the canonical server origin. Cookie Secure, HttpOnly and expiry attributes survive restoration. `SecureStore` uses memory only where Security.framework is unavailable; a non-Apple app must supply its own durable secret storage if persistence is needed. Passwords are never saved. Changing or clearing a session invalidates in-flight multi-request operations. The iOS facade removes legacy UserDefaults cookie data.

Public servers require HTTPS. HTTP is accepted only for localhost, `.local` names and private/link-local IP addresses. The consuming app must also configure platform transport entitlements/ATS rules for any intended LAN access.

## Safe control retries

Create and durably save a `PendingCall` **before** submitting a write. For social, approval and collaboration mutations, call `reserveOperation` before delivery; restore unresolved entries with `fetchOperations`. On a timeout, cancellation or `ControlCallError.uncertain`, keep that same request ID and parameters for reconciliation/retry; never silently make a fresh ID. The package performs at most 65 polling reads, with a 150-second overall limit and at most 30 seconds per HTTP request. Cancellation stops polling. Only the explicit not-executed agent error allowlist establishes rejection. Other authenticated errors can follow a committed action and remain uncertain, as do HTTP failures, malformed responses and expired writes. `collaboration.execute` with `action: "describe"` is read-only and never becomes a pending business operation.

`updateOperation` sends presentation hints; only the backend's authenticated agent response or snapshot can settle the operation. A completed conversation turn does not prove that an associated task or collaboration action succeeded. `sourceConversation` exposes agent-provided navigation provenance without granting authority.

Fetch and display platform policy before confirmation. `updatePolicy` accepts the exact displayed `policy_hash` with `confirm: true`, or an explicit `resume: true`. Pairing send checks reject `policy_paused` and `policy_unavailable` sync states. Saved account content remains readable during policy pauses.

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

The current fixture set includes attention pages and conversation notification targets. Run `bash scripts/check-contract-fixtures.sh` to check every fixture and the RPC method set against the sibling Web checkout. The shared module is a development and contract reference, not a runtime dependency of this Swift package.

Updating source or the Apple app does not update a running backend. The cross-client retry correction takes effect only after rebuilding and deploying the matching Web service to every serving replica; see the [shared module's rollout requirements](https://github.com/BillShiyaoZhang/agent-collaboration-web/blob/d56bf3557141821290c4a996f4fe98df56b5395d/packages/client-contract/README.md#cross-client-retries-and-rollout). The fixture comparison does not establish live cross-device behavior; full real-account and device acceptance remains outstanding.
