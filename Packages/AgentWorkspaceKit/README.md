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
- All 18 current `agent-comm-control/v1` methods, including attention, contact requests, direct messages, inbox read state, approval responses, collaboration actions, sender block/unblock and owner content review.
- Account-owned moderation report preview, single submission, original-ID reconciliation and recent report status. Support-handler consent is separate from AI content sharing.
- Platform policy disclosure/confirmation/pause/resume, revision-aware in-app notifications, durable operation reservations, saved conversation search/state, account record hiding/restoration and connection management.
- One-time agent connection authorization preview/approval, saved account activity, Codable workspace models, flexible `JSONValue` remote records, monotonic turn/snapshot merging and pairing/policy rules.

Registration returns an accepted response and sends an email verification link; it does not establish a signed-in session. New accounts must verify before credentials login. `WorkspaceClientError.emailNotVerified` distinguishes this requirement from an incorrect password. `resendVerification` and `requestPasswordReset` preserve the server's neutral response to avoid exposing whether an account exists. Email links complete verification/password recovery on the Web service.

`fetchWorkspace(conversationId: nil)` resumes the saved active conversation. An empty string explicitly requests a new conversation; a nonempty ID requests that conversation. This distinction is part of the workspace API contract. Check the [backend compatibility requirements](../../docs/DEVELOPMENT.md#服务端版本与兼容检查) against the server version you deploy.

## Session and trust boundary

This client talks over HTTPS to the Web backend using an isolated NextAuth cookie jar. It does not hold the agent's encryption keys or directly implement the platform's signed/encrypted transport: the Web backend verifies and decrypts agent responses. Each mutation sends the configured backend origin, which must agree with that deployment's `NEXTAUTH_URL` origin. The Swift client additionally correlates request IDs, method, protocol, response type and exactly one result/error. API redirects are rejected.

Apple platforms persist cookies in device-only Keychain entries scoped to the canonical server origin. Cookie Secure, HttpOnly and expiry attributes survive restoration. `SecureStore` uses memory only where Security.framework is unavailable; a non-Apple app must supply its own durable secret storage if persistence is needed. Passwords are never saved. Changing or clearing a session invalidates in-flight multi-request operations. The iOS facade removes legacy UserDefaults cookie data.

Public servers require HTTPS. HTTP is accepted only for localhost, `.local` names and private/link-local IP addresses. The consuming app must also configure platform transport entitlements/ATS rules for any intended LAN access.

## Safe control retries

`deleteAccount(currentPassword:expectedAccountID:)` is a separately confirmed destructive action against `/api/auth/delete-account`. The displayed account ID is a consistency assertion; the backend authenticates and chooses the target from its session. The method sends once and accepts only HTTP 200 with `deleted: true`. `AccountDeletionError.uncertain` distinguishes lost or malformed results from explicit HTTP rejection. It never retries or removes recovery data. After confirmed success, the app clears the session and exact recovery namespace, retains a local cleanup marker on failure, and resumes local cleanup before sign-in. `SecureStore.removeAll()` removes only its exact service, with an explicit match limit covering macOS and iOS.

Create and durably save a `PendingCall` **before** submitting a write. For social, approval and collaboration mutations, call `reserveOperation` before delivery; restore unresolved entries with `fetchOperations`. On a timeout, cancellation or `ControlCallError.uncertain`, keep that same request ID and parameters for reconciliation/retry; never silently make a fresh ID. The package performs at most 65 polling reads, with a 150-second overall limit and at most 30 seconds per HTTP request. Cancellation stops polling. Only the explicit not-executed agent error allowlist establishes rejection. Other authenticated errors can follow a committed action and remain uncertain, as do HTTP failures, malformed responses and expired writes. `collaboration.execute` with `action: "describe"` is read-only and never becomes a pending business operation.

`updateOperation` sends presentation hints; only the backend's authenticated agent response or snapshot can settle the operation. A completed conversation turn does not prove that an associated task or collaboration action succeeded. `sourceConversation` exposes agent-provided navigation provenance without granting authority.

Fetch and display platform policy before confirmation. `updatePolicy` accepts the exact displayed `policy_hash` with `confirm: true`, or an explicit `resume: true`. Pairing send checks reject `policy_paused` and `policy_unavailable` sync states. Saved account content remains readable during policy pauses.

The app owns its account/server-scoped durable submission journal and conversation drafts. The package does not choose a UI policy for discarding uncertain work.

## Peer content safety and reports

New content-bearing operations require both the Web-generated `contentSafety.version: 1` projection and the runtime's truthful `capabilities.peer_content_safety` declaration (`version: 1`, `mode: "owner_review"`, `automatic_peer_model_execution: false`). An incomplete declaration requires upgrading the helper and actual Hermes adapter; adding a flag to an old adapter does not implement the review boundary. Saved private conversation history and safety controls remain available according to existing policy and pairing permissions.

`contacts.block` and `contacts.unblock` require a receipt matching the exact sender URN, requested blocked state, connection status and nonnegative integer `safety_revision`. The revision is persistent for the owner; later receipts and snapshots supersede earlier state even if their receipt clocks move backwards. A block is enforced by the runtime, and unblocking does not release previously quarantined peer content. `inbox.review_preview` and `inbox.review` are explicit paired owner controls; model tools cannot approve their own input. Existing pairings do not gain these permissions automatically.

`previewContentReport` retrieves a bounded, exact preview for one account-owned record. Unreviewed or blocked content provides no raw evidence. `submitContentReport` makes one HTTP request and accepts only a matching HTTP 200 receipt. On a lost, nonfinal or malformed response, retain the original ID and exact request in account-scoped secure storage. Read it with `fetchContentReport` or explicitly retry the same ID and body; never silently create another report. `ContentReportError.uncertain` distinguishes an unknown outcome from an explicit rejection. Submission consent and attaching the preview are separate choices.

`PendingCall.encodeRequestBody()` produces deterministic transport JSON after dictionary reconstruction or journal decoding. Conversation sends serialize `text` before `conversation_id`, matching the existing Web client and older deployed backends whose request fingerprints depend on parameter key order. Additional keys and nested objects use stable sorted serialization. The client uses this serializer for every control submission.

## Verification and shared fixtures

The namespace-cleanup test writes disposable entries to two random `AgentWorkspaceKit.Tests.*` Keychain services, checks isolation and removes its own entries. It does not read real account credentials or recovery records. Other network tests use URLProtocol responses and make no live account calls.

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
