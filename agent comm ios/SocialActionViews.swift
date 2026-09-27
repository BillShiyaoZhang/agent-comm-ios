import SwiftUI
import AgentWorkspaceKit

struct SocialConfirmation: Identifiable {
    let id = UUID()
    let agentID: String?
    let method: RPCMethod
    let params: RemoteRecord
    let title: String
    let detail: String
    let explanation: String
    var approval: RemoteRecord? = nil
    var original: WorkspaceOperation? = nil
    var onSucceeded: (() -> Void)? = nil

    var isDestructive: Bool {
        method == .contactsBlock || (method == .collaborationExecute && ["revoke", "revoke_worker", "revoke_collaboration_maintenance"].contains(params.string("action")))
    }
}

struct SocialConfirmationSheet: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let action: SocialConfirmation
    @State private var checked = false
    @State private var submitting = false
    @State private var submissionMessage: String?
    @State private var requiresVerification = false
    @AccessibilityFocusState private var feedbackFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label(store.selectedAgent?.name ?? "当前 Agent", systemImage: "person.crop.circle").font(.headline)
                    Text(action.explanation).font(.subheadline).foregroundStyle(.secondary)
                    Text(action.detail).textSelection(.enabled).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading)
                    if let approval = action.approval, !socialDate(approval["expires_at"]).isEmpty {
                        Text("确认展示有效至：" + socialDate(approval["expires_at"])).font(.caption).foregroundStyle(.secondary)
                    }
                    if action.method.requiresContentSharing, let context = store.sharingContext {
                        AgentSharingDisclosure(context: context)
                        AgentSharingConsentControl(context: context).disabled(submitting)
                    }
                    Toggle("我已核对以上完整内容与接收方", isOn: $checked).font(.subheadline)
                    if action.agentID != store.selectedAgentID { InlineNotice(message: "当前 Agent 已切换，请关闭并重新核对。", style: .error) }
                    if let submissionMessage {
                        InlineNotice(message: submissionMessage, style: requiresVerification ? .info : .error)
                            .accessibilityFocused($feedbackFocused)
                        if requiresVerification { Text("关闭后，在协作页刷新并核实原请求，避免重复提交。").font(.subheadline).foregroundStyle(.secondary) }
                    }
                    submissionButton
                        .disabled(!checked || (action.method.requiresContentSharing && !store.hasAgentSharingPermission) || submitting || requiresVerification || action.agentID != store.selectedAgentID || !(action.original != nil ? store.canAct(action.method) : socialCanSubmit(store, action.method)))
                }.padding(20)
            }.background(Color.listBackground).navigationTitle(action.title)
                .crossPlatformNavigationBarTitleDisplayModeInline()
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Text(submissionMessage == nil ? "取消" : "关闭").workspaceTapTarget() }.disabled(submitting) } }
        }.interactiveDismissDisabled(submitting)
            .onChange(of: store.sharingContext) { _, _ in checked = false }
    }

    @ViewBuilder private var submissionButton: some View {
        if action.isDestructive {
            Button(role: .destructive, action: submit) { submissionLabel }.buttonStyle(.bordered)
        } else {
            Button(action: submit) { submissionLabel }.buttonStyle(WorkspacePrimaryButtonStyle())
        }
    }
    private var submissionLabel: some View {
        HStack {
            if submitting { ProgressView().accessibilityHidden(true) }
            Text(submitting ? "正在提交…" : action.title)
        }.frame(maxWidth: .infinity).workspaceTapTarget()
    }
    private func submit() {
        guard !submitting, checked, !action.method.requiresContentSharing || store.hasAgentSharingPermission, !requiresVerification, action.agentID == store.selectedAgentID else { return }
        let existingIDs = Set(store.actionOperations.map { $0.call.requestId })
        submitting = true
        submissionMessage = nil
        store.actionResult = nil
        store.error = nil
        Task {
            if let original = action.original { await store.retryAction(original) }
            else if let approval = action.approval { await store.confirmApproval(approval, decision: action.params.string("decision")) }
            else { await store.performAction(action.method, params: action.params) }
            submitting = false
            guard action.agentID == store.selectedAgentID else { return }
            let operation = store.actionOperations.first { operation in
                guard operation.call.method == action.method, operation.call.params == action.params else { return false }
                if let original = action.original { return operation.call.requestId == original.call.requestId }
                return !existingIDs.contains(operation.call.requestId)
            }
            if operation?.phase == "succeeded" {
                action.onSucceeded?()
                dismiss()
            } else {
                requiresVerification = operation.map { ["sending", "uncertain"].contains($0.phase) } ?? (store.actionResult != nil)
                submissionMessage = store.error ?? store.actionResult ?? "操作未提交。请检查连接与当前权限后重新核对。"
                checked = false
                feedbackFocused = true
            }
        }
    }
}

struct SocialActionFeedback: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var confirmation: SocialConfirmation?
    @State private var sharingDisclosure: AgentSharingContext?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let context = store.sharingContext {
                Button { sharingDisclosure = context } label: { Label("管理共享授权", systemImage: "hand.raised").workspaceTapTarget() }
                    .font(.caption).accessibilityValue(store.hasAgentSharingPermission ? "已允许，可撤回" : "尚未允许")
            }
            if let result = store.actionResult { InlineNotice(message: result, style: resultStyle) }
            if let response = store.actionResponse, !response.isEmpty {
                DisclosureGroup { SnapshotDetails(data: response).padding(.top, 8) } label: { Text("最近操作的 Agent 返回结果").frame(maxWidth: .infinity, alignment: .leading).workspaceTapTarget() }.font(.caption)
            }
            if !store.uncertainActions.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("原请求已保留。先刷新或在本机核实结果，避免创建重复动作。").font(.caption).foregroundStyle(.secondary)
                        ForEach(store.uncertainActions, id: \.call.requestId) { action in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(action.message.isEmpty ? "Agent 尚未确认结果" : action.message).font(.subheadline)
                                Text(action.call.method.rawValue + " · " + action.call.requestId).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                                SnapshotDetails(data: action.call.params)
                                if action.retryable {
                                    Button {
                                        confirmation = SocialConfirmation(agentID: store.selectedAgentID, method: action.call.method, params: action.call.params, title: "确认继续提交原请求", detail: socialPretty(action.call.params), explanation: "沿用原请求 ID：\(action.call.requestId)。继续本次提交，不会创建新操作。请先核对已同步状态与以下完整内容。", original: action)
                                    } label: { Text("继续提交原请求").workspaceTapTarget() }.font(.caption).buttonStyle(.bordered).disabled(!store.canAct(action.call.method))
                                }
                            }.padding(12).background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
                        }
                        Button { Task { await store.refresh(schedule: true) } } label: { Text("刷新核实结果").workspaceTapTarget() }.buttonStyle(.bordered).disabled(store.busy != nil || store.demo)
                    }.padding(.top, 8)
                } label: { Text("\(store.uncertainActions.count) 项提交结果待核实").frame(maxWidth: .infinity, alignment: .leading).workspaceTapTarget() }.font(.subheadline).foregroundStyle(Color.statusWarning)
            }
        }.sheet(item: $confirmation) { SocialConfirmationSheet(action: $0) }
            .sheet(item: $sharingDisclosure) { AgentSharingPermissionView(context: $0) }
    }
    private var resultStyle: InlineNotice.NoticeStyle {
        switch store.actionOperations.first(where: { $0.message == store.actionResult })?.phase {
        case "succeeded": return .success
        case "failed": return .error
        default: return .info
        }
    }
}

struct AddContactForm: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var name = ""
    @State private var aliases = ""
    @State private var urn = ""
    @State private var error: String?
    @State private var confirmation: SocialConfirmation?

    var body: some View {
        WorkspaceCard {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 14) {
                    Text("本机 Agent 会排队并尝试投递好友请求。对方收到并接受后，双方才建立通讯录连接。").font(.caption).foregroundStyle(.secondary)
                    WorkspaceField(title: "姓名或称呼") { TextField("例如：小王", text: $name).workspaceInputStyle() }
                    WorkspaceField(title: "其他别名（可选）") { TextField("多个别名用逗号分隔", text: $aliases).workspaceInputStyle() }
                    WorkspaceField(title: "对方的完整 URN", hint: "请通过可信渠道获取对方 Agent 的准确 URN，并按本机 Agent 的要求核对公钥。") {
                        TextField("urn:agent-comm:agent:…", text: $urn).crossPlatformAutocapitalization().autocorrectionDisabled().workspaceInputStyle()
                    }
                    if let error { InlineNotice(message: error, style: .error) }
                    Button { prepare() } label: { Text("核对并添加联系人").workspaceTapTarget() }.buttonStyle(.borderedProminent).disabled(!store.canAct(.contactsAdd) || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || urn.isEmpty)
                    SocialCapabilityHint(method: .contactsAdd)
                }.padding(.top, 12)
            } label: { Text("添加联系人").frame(maxWidth: .infinity, alignment: .leading).workspaceTapTarget() }
        }.sheet(item: $confirmation) { SocialConfirmationSheet(action: $0) }
    }
    private func prepare() {
        error = nil
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUrn = urn.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        let names = ([cleanName] + aliases.components(separatedBy: CharacterSet(charactersIn: ",，、\n"))).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !cleanName.isEmpty, names.count <= 16, names.allSatisfy({ $0.utf16.count <= 100 }) else { error = "姓名和别名合计最多 16 个，每个最多 100 字。"; return }
        guard socialValidUrn(cleanUrn) else { error = "请填写完整的联系人 URN，最多 256 字。"; return }
        if store.contacts.contains(where: { $0.string("urn") == cleanUrn }) { error = "这条 URN 已有联系人记录，请核对下方联系人；已拒绝的请求可从该卡片重新发起。"; return }
        confirmation = SocialConfirmation(agentID: store.selectedAgentID, method: .contactsAdd,
            params: ["contact_id": .string("contact-" + UUID().uuidString.lowercased()), "aliases": .array(names.map(JSONValue.string)), "urn": .string(cleanUrn)],
            title: "添加并排队好友请求", detail: "通讯录称呼：\(names.joined(separator: "、"))\n\n对方 URN：\n\(cleanUrn)",
            explanation: "称呼仅用于你的通讯录。接受只开通普通消息，不代表已核实对方现实身份或授予协作权限。请求可能仍待投递。", onSucceeded: { name = ""; aliases = ""; urn = "" })
    }
}

struct ContactRequestsView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var historyOpen = false
    var body: some View {
        if !store.contactRequests.isEmpty {
            WorkspaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("好友请求").font(.headline)
                    Text("接受后开通普通消息；协作仍需单独授权。").font(.caption).foregroundStyle(.secondary)
                    let pending = store.contactRequests.filter { $0.string("status") == "pending" }
                    ForEach(socialRecordRows(Array(pending.reversed()), key: "request_id")) { item in ContactRequestCard(request: item.data).id(item.data.string("request_id")) }
                    let history = store.contactRequests.filter { $0.string("status") != "pending" }
                    if !history.isEmpty { DisclosureGroup(isExpanded: $historyOpen) { ForEach(socialRecordRows(Array(history.reversed()), key: "request_id")) { item in ContactRequestCard(request: item.data).id(item.data.string("request_id")) } } label: { Text("已处理的请求 · \(history.count)").frame(maxWidth: .infinity, alignment: .leading).workspaceTapTarget() } }
                }
            }.task(id: store.collaborationFocusID) { if let id = store.collaborationFocusID, store.contactRequests.contains(where: { $0.string("request_id") == id && $0.string("status") != "pending" }) { historyOpen = true } }
        }
    }
}

struct ContactRequestCard: View {
    @EnvironmentObject private var store: WorkspaceStore
    let request: RemoteRecord
    @State private var confirmation: SocialConfirmation?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkspaceAdaptiveStack { Text(request.string("direction") == "incoming" ? "收到的请求" : "发起的请求").font(.caption); Text(requestStatus).font(.caption).foregroundStyle(.secondary) }.accessibilityElement(children: .combine)
            Text(request.string("peer_urn")).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            PeerSafetyControls(urn: request.string("peer_urn"))
            ContentReportButton(kind: "contact_request", recordID: request.string("request_id"))
            Text(socialDate(request["updated_at"] ?? request["created_at"])).font(.caption2).foregroundStyle(.secondary)
            if request.string("direction") == "incoming" && request.string("status") == "pending" {
                WorkspaceAdaptiveStack {
                    Button { prepare("accept") } label: { Text("接受好友请求").workspaceTapTarget() }.buttonStyle(.borderedProminent)
                    Button { prepare("reject") } label: { Text("拒绝").workspaceTapTarget() }.buttonStyle(.bordered)
                }.disabled(!store.canAct(.contactsRespond) || request.string("request_id").isEmpty || socialLocked(store, .contactsRespond, "request_id", request.string("request_id")))
            }
        }.padding(12).background(Color.listBackground, in: RoundedRectangle(cornerRadius: 12))
            .sheet(item: $confirmation) { SocialConfirmationSheet(action: $0) }
    }
    private var requestStatus: String {
        switch request.string("status") { case "pending": return request.string("direction") == "incoming" ? "等待你处理" : "待投递或等待对方处理"; case "accepted": return "已建立通讯录连接"; case "rejected": return "已拒绝"; default: return stateText(request.string("status")) }
    }
    private func prepare(_ decision: String) {
        confirmation = SocialConfirmation(agentID: store.selectedAgentID, method: .contactsRespond, params: ["request_id": .string(request.string("request_id")), "decision": .string(decision)],
            title: decision == "accept" ? "确认接受好友请求" : "确认拒绝好友请求", detail: "对方 URN：\n\(request.string("peer_urn"))\n\n请求：\(request.string("request_id"))", explanation: decision == "accept" ? "接受后建立通讯录连接，可以互发普通消息；这不会授予协作权限，也不代表已核实对方现实身份。" : "本机 Agent 将记录并处理对这条好友请求的拒绝。")
    }
}

struct ContactCard: View {
    @EnvironmentObject private var store: WorkspaceStore
    let contact: RemoteRecord
    let syncedAt: Double
    @State private var confirmation: SocialConfirmation?
    var body: some View {
        WorkspaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack { AgentAvatar(name: socialContactName(contact), size: 38).accessibilityHidden(true); Text(socialContactName(contact)).font(.headline); Spacer() }
                Text(connectionLabel).font(.caption).foregroundStyle(.secondary)
                if contact.string("connection_status") == "connected" && !store.peerIsBlocked(contact.string("urn")) {
                    TimelineView(.periodic(from: .now, by: 30)) { timeline in
                        let presence = presenceLabel(at: timeline.date)
                        Label(presence.0, systemImage: "circle.fill").font(.caption).foregroundStyle(presence.1 ? Color.statusSuccess : Color.secondary)
                    }
                }
                if contact.strings("aliases").count > 1 { Text(contact.strings("aliases").dropFirst().joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                Text(contact.string("urn")).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                if !contact.string("urn").isEmpty { CopyLabel(value: contact.string("urn"), title: "复制 URN") }
                PeerSafetyControls(urn: contact.string("urn"))
                ContentReportButton(kind: "contact", recordID: contact.string("contact_id"))
                if contact.string("connection_status") == "rejected" {
                    Text("上次好友请求已被拒绝。重新发起会沿用本机联系人记录，并由 Agent 核对当前状态。").font(.caption).foregroundStyle(.secondary)
                    Button {
                        let aliases = contact.strings("aliases").isEmpty ? [socialContactName(contact)] : contact.strings("aliases")
                        confirmation = SocialConfirmation(agentID: store.selectedAgentID, method: .contactsAdd, params: ["contact_id": .string(contact.string("contact_id")), "urn": .string(contact.string("urn")), "aliases": .array(aliases.map(JSONValue.string))], title: "确认重新发起", detail: "通讯录称呼：\(aliases.joined(separator: "、"))\n\n对方 URN：\n\(contact.string("urn"))", explanation: "仅当仍无在途请求且尚未连接，Agent 才会生成独立的新请求。旧请求仍保留已拒绝状态。")
                    } label: { Text("重新发起好友请求").workspaceTapTarget() }.buttonStyle(.bordered).disabled(!store.canAct(.contactsAdd) || contact.string("contact_id").isEmpty || !socialValidUrn(contact.string("urn")))
                }
                if contact.string("connection_status") == "connected" && !store.peerIsBlocked(contact.string("urn")) { PeerMessageForm(recipientUrn: contact.string("urn"), compact: true) }
                PeerCommunicationView(recipientUrn: contact.string("urn"))
                SocialRecordAction(kind: "contact", recordID: contact.string("contact_id"), title: socialContactName(contact))
            }
        }.sheet(item: $confirmation) { SocialConfirmationSheet(action: $0) }
    }
    private var connectionLabel: String {
        if store.peerIsBlocked(contact.string("urn")) { return "已在这个 Agent 屏蔽" }
        switch contact.string("connection_status") { case "blocked": return "已在这个 Agent 屏蔽"; case "connected": return "已建立通讯录连接"; case "pending", "requested": return "请求待投递或待对方处理"; case "rejected": return "好友请求已拒绝"; default: return "尚未建立通讯录连接" }
    }
    private func presenceLabel(at now: Date) -> (String, Bool) {
        let presence = contact.record("presence")
        if presence.string("status") == "online", let expiry = socialRemoteDate(presence["expires_at"]), expiry > now { return ("在线", true) }
        if presence.string("status") == "offline", syncedAt > 0, now.timeIntervalSince1970 * 1000 - syncedAt < 60_000 { return ("离线", false) }
        return ("在线状态待更新", false)
    }
}

struct PeerMessageForm: View {
    @EnvironmentObject private var store: WorkspaceStore
    var recipientUrn = ""
    var compact = false
    @State private var recipient = ""
    @State private var text = ""
    @State private var error: String?
    @State private var confirmation: SocialConfirmation?
    @ScaledMetric(relativeTo: .body) private var editorHeight = 110.0
    private var cleanRecipient: String { (recipientUrn.isEmpty ? recipient : recipientUrn).trimmingCharacters(in: .whitespacesAndNewlines) }
    private var contacts: [RemoteRecord] { store.contacts.filter { $0.string("connection_status") == "connected" && $0.string("contact_id") != "self" && !$0.string("urn").isEmpty } }

    var body: some View {
        Group {
            if compact { form }
            else { WorkspaceCard { form } }
        }.sheet(item: $confirmation) { SocialConfirmationSheet(action: $0) }
    }
    private var form: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                if recipientUrn.isEmpty {
                    Picker("选择联系人", selection: $recipient) {
                        Text("选择已连接的联系人").tag("")
                        ForEach(socialRecordRows(contacts, key: "contact_id", fallbackKeys: ["urn"])) { item in Text(socialContactName(item.data)).tag(item.data.string("urn")) }
                    }.pickerStyle(.menu).workspaceTapTarget()
                    if contacts.isEmpty { Text("还没有已连接的联系人。请先在「联系人」中添加并等待对方接受。").font(.subheadline).foregroundStyle(.secondary) }
                    DisclosureGroup { TextField("好友的完整 URN", text: $recipient).crossPlatformAutocapitalization().autocorrectionDisabled().workspaceInputStyle() } label: { Text("填写确切接收方 URN").frame(maxWidth: .infinity, alignment: .leading).workspaceTapTarget() }.font(.caption)
                }
                if !cleanRecipient.isEmpty { Text("由本机 Agent 发给：\n" + cleanRecipient).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                TextEditor(text: $text).frame(minHeight: editorHeight).padding(8).background(Color.listBackground, in: RoundedRectangle(cornerRadius: 12)).accessibilityLabel("发送给好友的消息")
                Text("消息最多 24 KB；本机受理、实际投递和对方已读分别核验。").font(.caption).foregroundStyle(.secondary)
                if let error { InlineNotice(message: error, style: .error) }
                Button { prepare() } label: { Text("核对并发送消息").workspaceTapTarget() }.buttonStyle(.borderedProminent)
                    .disabled(!store.canAct(.messagesSend) || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || cleanRecipient.isEmpty || socialLocked(store, .messagesSend, "recipient_urn", cleanRecipient))
                SocialCapabilityHint(method: .messagesSend)
            }.padding(.top, 10)
        } label: { Text(compact ? "发送消息 / 回复" : "给好友发消息").frame(maxWidth: .infinity, alignment: .leading).workspaceTapTarget() }
    }
    private func prepare() {
        error = nil
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard socialValidUrn(cleanRecipient) else { error = "请输入对方的完整 URN。"; return }
        guard !content.isEmpty, content.utf8.count <= 24_000 else { error = "消息不能为空，内容不能超过 24 KB。"; return }
        confirmation = SocialConfirmation(agentID: store.selectedAgentID, method: .messagesSend,
            params: ["recipient_urn": .string(cleanRecipient), "text": .string(content), "message_id": .string("message-" + UUID().uuidString.lowercased())], title: "确认发送消息",
            detail: "接收方 URN：\n\(cleanRecipient)\n\n消息全文：\n\(content)", explanation: "这条普通消息将由你的本机 Agent 发给该接收方。发送消息不会授予协作权限；本机受理尚不能证明对方已读。", onSucceeded: { text = "" })
    }
}

struct InboxMessageCard: View {
    @EnvironmentObject private var store: WorkspaceStore
    let message: RemoteRecord
    var body: some View {
        WorkspaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(message.string("sender_urn", default: "对端 Agent"), systemImage: "arrow.down.left").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                PeerSafetyControls(urn: message.string("sender_urn"))
                ContentReportButton(kind: "inbox", recordID: message.string("message_id"))
                if store.peerIsBlocked(message.string("sender_urn")) { Label("此发送方已被屏蔽，正文保持隐藏", systemImage: "hand.raised").font(.caption) }
                else if peerContentApproved(message), store.contentSafetyAvailable || store.demo {
                    Text(socialMessageText(message.string("text"))).textSelection(.enabled).lineSpacing(4)
                } else { PendingContentReview(messageID: message.string("message_id"), status: message.record("content_review").string("status", default: "pending")) }
                Text(socialDate(message["received_at"])).font(.caption).foregroundStyle(.secondary)
                if message.bool("unknown_sender") { Text("这位发送者尚未建立好友连接。").font(.caption).foregroundStyle(Color.statusWarning) }
                if peerContentApproved(message), !store.peerIsBlocked(message.string("sender_urn")), store.contentSafetyAvailable || store.demo {
                    MessageReadButton(message: message)
                    if !message.bool("unknown_sender") && !message.string("sender_urn").isEmpty { PeerMessageForm(recipientUrn: message.string("sender_urn"), compact: true) }
                }
                if !message.string("task_id").isEmpty { Text("事项 · " + message.string("task_id")).font(.caption).foregroundStyle(.secondary) }
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message.string("message_id")).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        RelatedConversationLink(source: message.record("source_context"))
                    }.padding(.top, 8)
                } label: { Text("来源与确切标识").frame(maxWidth: .infinity, alignment: .leading).workspaceTapTarget() }.font(.caption)
            }
        }
    }
}

struct MessageReadButton: View {
    @EnvironmentObject private var store: WorkspaceStore
    let message: RemoteRecord
    @State private var confirmation: SocialConfirmation?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message.bool("read") ? "已读 · Agent 已记录" : "未读").font(.caption).foregroundStyle(.secondary)
            if !message.bool("read") {
                Button {
                    confirmation = SocialConfirmation(agentID: store.selectedAgentID, method: .inboxMarkRead, params: ["message_id": .string(message.string("message_id"))], title: "确认标为已读", detail: "消息来源：\n\(message.string("sender_urn"))\n\n消息全文：\n\(socialMessageText(message.string("text")))", explanation: "将此消息的已读状态同步到本机 Agent，并关闭对应提醒。这不会批准消息中的请求。")
                } label: { Text("标为已读并关闭提醒").workspaceTapTarget() }.font(.caption).buttonStyle(.bordered).disabled(!store.canAct(.inboxMarkRead) || message.string("message_id").isEmpty || socialLocked(store, .inboxMarkRead, "message_id", message.string("message_id")))
            }
        }.sheet(item: $confirmation) { SocialConfirmationSheet(action: $0) }
    }
}

struct SentMessagesView: View {
    @EnvironmentObject private var store: WorkspaceStore
    var body: some View {
        if !store.sentMessages.isEmpty {
            WorkspaceCard {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(socialRecordRows(Array(store.sentMessages.reversed()), key: "message_id")) { item in
                            let message = item.data
                            VStack(alignment: .leading, spacing: 8) {
                                Text("发给 " + message.string("recipient_urn")).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                Text(message.string("text")).font(.subheadline).textSelection(.enabled)
                                Text(socialSentStatus(message.string("status"))).font(.caption).foregroundStyle(.secondary)
                                Text(socialDate(message["created_at"])).font(.caption2).foregroundStyle(.secondary)
                            }.padding(12).background(Color.listBackground, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }.padding(.top, 10)
                } label: { Text("已发送消息 · \(store.sentMessages.count)").frame(maxWidth: .infinity, alignment: .leading).workspaceTapTarget() }
            }
        }
    }
}

struct PeerCommunicationView: View {
    @EnvironmentObject private var store: WorkspaceStore
    let recipientUrn: String
    private var messages: [RemoteRecord] {
        (store.inbox.filter { $0.string("sender_urn") == recipientUrn }.map { var copy = $0; copy["direction"] = "incoming"; return copy }
         + store.sentMessages.filter { $0.string("recipient_urn") == recipientUrn }.map { var copy = $0; copy["direction"] = "outgoing"; return copy })
        .sorted { (socialRemoteDate($0["received_at"] ?? $0["created_at"]) ?? .distantPast) < (socialRemoteDate($1["received_at"] ?? $1["created_at"]) ?? .distantPast) }
    }
    var body: some View {
        if !recipientUrn.isEmpty && !messages.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    Text("打开记录不会自动写入 Agent 已读，也不会授权。覆盖本账户已保存的普通通信。").font(.caption).foregroundStyle(.secondary)
                    ForEach(socialRecordRows(messages, key: "message_id", namespaceKey: "direction")) { item in
                        let message = item.data
                        VStack(alignment: .leading, spacing: 8) {
                            let incoming = message.string("direction") == "incoming"
                            Text(incoming ? "对端 Agent 来信 · 对端声明" : "本方 Agent 发送记录").font(.caption).foregroundStyle(.secondary)
                            if !incoming || (peerContentApproved(message) && store.contentSafetyAvailable && !store.peerIsBlocked(recipientUrn)) {
                                Text(socialMessageText(message.string("text"))).font(.subheadline).textSelection(.enabled)
                            } else { PendingContentReview(messageID: message.string("message_id"), status: message.record("content_review").string("status", default: "pending")) }
                            Text(socialDate(message["received_at"] ?? message["created_at"])).font(.caption2).foregroundStyle(.secondary)
                            if incoming && peerContentApproved(message) && store.contentSafetyAvailable && !store.peerIsBlocked(recipientUrn) { MessageReadButton(message: message) }
                            else { Text(socialSentStatus(message.string("status"))).font(.caption).foregroundStyle(.secondary) }
                            Text(message.string("message_id")).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        }.padding(12).background(Color.listBackground, in: RoundedRectangle(cornerRadius: 12))
                    }
                }.padding(.top, 10)
            } label: { Text("通信记录 · \(messages.count) 条").frame(maxWidth: .infinity, alignment: .leading).workspaceTapTarget() }.font(.caption)
        }
    }
}

struct ApprovalRequestCard: View {
    @EnvironmentObject private var store: WorkspaceStore
    let approval: RemoteRecord
    @State private var confirmation: SocialConfirmation?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkspaceAdaptiveStack { Text(approval.string("subject_id", default: "待确认请求")).font(.subheadline.bold()); RemoteStatus(status: approval.string("status")) }
            Text(approval.string("question", default: "本次同步缺少请求内容，请刷新后再回应。")).font(.subheadline).textSelection(.enabled).lineSpacing(4)
            if !socialDate(approval["expires_at"]).isEmpty { Text("确认展示有效至：" + socialDate(approval["expires_at"])).font(.caption).foregroundStyle(.secondary) }
            if approval.string("status") == "expired" || (socialRemoteDate(approval["expires_at"]).map { $0 <= Date() } ?? false) {
                Text("上次确认展示已过期，请重新核对全文。Agent 会检查事项是否仍有效。").font(.caption).foregroundStyle(Color.statusWarning)
            }
            WorkspaceAdaptiveStack {
                Button { prepare("approve") } label: { Text("同意本次请求").workspaceTapTarget() }.buttonStyle(.borderedProminent)
                Button { prepare("deny") } label: { Text("拒绝本次请求").workspaceTapTarget() }.buttonStyle(.bordered)
            }.disabled(!canDecide || socialLocked(store, .approvalRespond, "approval_id", approval.string("approval_id")))
            SocialCapabilityHint(method: .approvalRespond)
            RelatedConversationLink(source: approval.record("source_context"))
        }.padding(14).background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 14))
            .sheet(item: $confirmation) { SocialConfirmationSheet(action: $0) }
    }
    private var canDecide: Bool { store.canAct(.approvalRespond) && !approval.string("approval_id").isEmpty && !approval.string("question").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ["pending", "presenting", "expired"].contains(approval.string("status")) }
    private func prepare(_ decision: String) {
        confirmation = SocialConfirmation(agentID: store.selectedAgentID, method: .approvalRespond, params: ["approval_id": .string(approval.string("approval_id")), "decision": .string(decision)], title: decision == "approve" ? "确认同意本次请求" : "确认拒绝本次请求", detail: approval.string("question"), explanation: "提交前会重新核验 Agent 的当前完整问题。若问题、对象或状态已更新，本次决定不会提交。批准只允许问题中列明的确切范围。", approval: approval)
    }
}

private struct MeetingGoalWindow: Identifiable {
    let id = UUID()
    var start = Date().addingTimeInterval(3600)
    var end = Date().addingTimeInterval(7200)
}

private struct MeetingDateField: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    var accessibilityTitle: String? = nil
    @Binding var selection: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if dynamicTypeSize.isAccessibilitySize {
                Text(title).accessibilityHidden(true)
                DatePicker(title, selection: $selection).labelsHidden()
                    .accessibilityLabel(accessibilityTitle ?? title)
            } else {
                DatePicker(title, selection: $selection)
                    .accessibilityLabel(accessibilityTitle ?? title)
            }
        }
    }
}

struct MeetingGoalForm: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var contactID = ""
    @State private var goal = ""
    @State private var success = ""
    @State private var topic = ""
    @State private var windows = [MeetingGoalWindow()]
    @State private var expiresAt = Date().addingTimeInterval(172_800)
    @State private var duration = "60"
    @State private var candidates = "3"
    @State private var budget = "10"
    @State private var propose = true
    @State private var accept = true
    @State private var shareSlots = false
    @State private var resourceIDs = Set<String>()
    @State private var confirmation: SocialConfirmation?
    @State private var error: String?
    private var contacts: [RemoteRecord] { store.contacts.filter { $0.string("connection_status") == "connected" && $0.string("contact_id") != "self" && !$0.string("urn").isEmpty } }
    private var resources: [RemoteRecord] { store.collaboration.records("resources").filter { !$0.string("resource_id").isEmpty } }
    private var supported: Bool {
        let fields = store.collaborationDescription.record("action_fields").record("prepare_task")
        return store.collaborationDescription.strings("actions").contains("prepare_task") && fields.strings("required").contains("scope") && Set(fields.strings("required")).isSubset(of: ["scope", "task_id"])
    }
    private var businessCapabilities: [String] { store.collaborationDescription.strings("business_capabilities") }
    var body: some View {
        if store.available(.collaborationExecute) || store.demo {
            WorkspaceCard {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("先明确目标、成功标准与本方范围。准备委托后，你仍需核对完整授权问题；双方约定、实际投递与会议举行分别核验。").font(.caption).foregroundStyle(.secondary)
                        if !supported {
                            Button { Task { await store.describeCollaboration() } } label: { Text("读取本机支持的协作功能").workspaceTapTarget() }.buttonStyle(.bordered).disabled(!store.canAct(.collaborationExecute))
                            if !store.collaborationDescription.isEmpty { Text("本机尚未提供此向导所需的范围字段；可使用下方实际开放的功能。").font(.caption).foregroundStyle(.secondary) }
                        } else {
                            goalFields
                            timeFields
                            permissionFields
                            if let error { InlineNotice(message: error, style: .error) }
                            Button { prepare() } label: { Text("核对并准备委托").workspaceTapTarget() }.buttonStyle(.borderedProminent).disabled(!socialCanSubmit(store, .collaborationExecute) || contactID.isEmpty)
                        }
                        SocialCapabilityHint(method: .collaborationExecute)
                    }.padding(.top, 12)
                } label: { Text("创建会议协作目标").frame(maxWidth: .infinity, alignment: .leading).workspaceTapTarget() }
            }.sheet(item: $confirmation) { SocialConfirmationSheet(action: $0) }
        }
    }
    private var goalFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("协作联系人", selection: $contactID) {
                Text("选择已连接的联系人").tag("")
                ForEach(socialRecordRows(contacts, key: "contact_id", fallbackKeys: ["urn"])) { item in Text(socialContactName(item.data)).tag(item.data.string("contact_id")) }
            }.pickerStyle(.menu).workspaceTapTarget()
            if contacts.isEmpty { Text("请先在「联系人」中添加联系人，并等待对方接受后再创建会议协作目标。").font(.subheadline).foregroundStyle(.secondary) }
            WorkspaceField(title: "要达成什么目标") { TextField("例如：与设计伙伴安排方案评审", text: $goal, axis: .vertical).workspaceInputStyle() }
            WorkspaceField(title: "怎样算成功") { TextField("例如：双方确认一个 60 分钟线上会议时段", text: $success, axis: .vertical).workspaceInputStyle() }
            WorkspaceField(title: "会议主题") { TextField("主题", text: $topic).workspaceInputStyle() }
        }
    }
    private var timeFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("可选时间范围 · 本设备时区").font(.subheadline.bold())
            ForEach($windows) { $window in
                let number = (windows.firstIndex { $0.id == window.id } ?? 0) + 1
                VStack(alignment: .leading, spacing: 8) {
                    MeetingDateField(title: "开始", accessibilityTitle: "第 \(number) 个范围的开始时间", selection: $window.start)
                    MeetingDateField(title: "结束", accessibilityTitle: "第 \(number) 个范围的结束时间", selection: $window.end)
                    if windows.count > 1 { Button(role: .destructive) { windows.removeAll { $0.id == window.id } } label: { Text("移除此时间范围").workspaceTapTarget() }.font(.caption).accessibilityLabel("移除第 \(number) 个时间范围") }
                }.padding(12).background(Color.listBackground, in: RoundedRectangle(cornerRadius: 12))
            }
            Button { windows.append(MeetingGoalWindow()) } label: { Text("增加时间范围").workspaceTapTarget() }.font(.caption).buttonStyle(.bordered).disabled(windows.count >= 16)
            MeetingDateField(title: "本方授权截止", selection: $expiresAt)
            WorkspaceField(title: "最长会议分钟数") { TextField("60", text: $duration).crossPlatformKeyboardType(.decimal).workspaceInputStyle() }
            WorkspaceField(title: "最多披露的候选时段数") { TextField("3", text: $candidates).crossPlatformKeyboardType(.decimal).workspaceInputStyle() }
            WorkspaceField(title: "最多业务动作次数") { TextField("10", text: $budget).crossPlatformKeyboardType(.decimal).workspaceInputStyle() }
        }
    }
    private var permissionFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("允许的确切能力").font(.subheadline.bold())
            if businessCapabilities.contains("propose_meeting") { Toggle("提出范围内的会议方案", isOn: $propose) }
            if businessCapabilities.contains("accept_meeting") { Toggle("接受范围内的会议方案", isOn: $accept) }
            if businessCapabilities.contains("share_slots") { Toggle("分享候选时段", isOn: $shareSlots) }
            if businessCapabilities.contains("share_resource") && !resources.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(socialRecordRows(resources, key: "resource_id")) { item in
                            let resource = item.data
                            Toggle(resource.string("title", default: resource.string("resource_id")), isOn: Binding(get: { resourceIDs.contains(resource.string("resource_id")) }, set: { selected in if selected { resourceIDs.insert(resource.string("resource_id")) } else { resourceIDs.remove(resource.string("resource_id")) } }))
                            DisclosureGroup { Text(resource.string("text")).font(.caption).textSelection(.enabled) } label: { Text("核对资料全文").frame(maxWidth: .infinity, alignment: .leading).workspaceTapTarget() }
                        }
                    }.padding(.top, 8)
                } label: { Text("允许分享的注册资料").frame(maxWidth: .infinity, alignment: .leading).workspaceTapTarget() }
            }
            Text("允许分享只涵盖所选资料全文，不代表已经披露。此委托不会自动开启有限后台运行。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func prepare() {
        error = nil
        guard let contact = contacts.first(where: { $0.string("contact_id") == contactID }) else { error = "请选择当前已连接的联系人。"; return }
        let purpose = "目标：" + goal.trimmingCharacters(in: .whitespacesAndNewlines) + "\n成功标准：" + success.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !success.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !cleanTopic.isEmpty, purpose.utf16.count <= 1000, cleanTopic.utf16.count <= 500 else { error = "请填写目标、成功标准与主题；目标和成功标准合计最多 990 字，主题最多 500 字。"; return }
        guard !windows.isEmpty, windows.count <= 16, windows.allSatisfy({ $0.start < $0.end }), expiresAt > Date() else { error = "请提供有效的时间范围，并将授权截止设为未来时间。"; return }
        guard let minutes = Int(duration), (1...10080).contains(minutes), let count = Int(candidates), (1...128).contains(count), let actions = Int(budget), (1...100000).contains(actions) else { error = "请输入有效的会议时长、候选时段数和动作次数。"; return }
        var capabilities: [String] = []
        if propose && businessCapabilities.contains("propose_meeting") { capabilities.append("propose_meeting") }; if accept && businessCapabilities.contains("accept_meeting") { capabilities.append("accept_meeting") }; if shareSlots && businessCapabilities.contains("share_slots") { capabilities.append("share_slots") }
        let selectedResources = resources.filter { businessCapabilities.contains("share_resource") && resourceIDs.contains($0.string("resource_id")) }
        if !selectedResources.isEmpty { capabilities.append("share_resource") }
        guard !capabilities.isEmpty else { error = "请选择至少一项允许能力。"; return }
        let formatter = ISO8601DateFormatter()
        let scope: RemoteRecord = ["purpose": .string(purpose), "topic": .string(cleanTopic), "capabilities": .array(capabilities.map(JSONValue.string)), "recipient_ids": [.string(contactID)], "participant_ids": ["self", .string(contactID)], "resource_ids": .array(selectedResources.map { .string($0.string("resource_id")) }), "window_start": .string(formatter.string(from: windows.map(\.start).min()!)), "window_end": .string(formatter.string(from: windows.map(\.end).max()!)), "allowed_windows": .array(windows.map { .object(["start": .string(formatter.string(from: $0.start)), "end": .string(formatter.string(from: $0.end))]) }), "max_duration_minutes": .number(Double(minutes)), "max_candidates": .number(Double(count)), "max_actions": .number(Double(actions)), "expires_at": .string(formatter.string(from: expiresAt))]
        let taskFields = store.collaborationDescription.record("action_fields").record("prepare_task")
        var rawParams: RemoteRecord = ["action": "prepare_task", "scope": .object(scope)]
        if (taskFields.strings("required") + taskFields.strings("optional")).contains("task_id") { rawParams["task_id"] = .string("task-" + UUID().uuidString.lowercased()) }
        let params = socialWithSource(store, rawParams)
        let resourceText = selectedResources.map { "\($0.string("title"))\n\($0.string("text"))" }.joined(separator: "\n\n")
        confirmation = SocialConfirmation(agentID: store.selectedAgentID, method: .collaborationExecute, params: params, title: "确认准备协作委托", detail: "协作联系人：\(socialContactName(contact))\n\(contact.string("urn"))\n\n\(socialPretty(scope))" + (resourceText.isEmpty ? "" : "\n\n允许分享的资料全文：\n" + resourceText), explanation: "这次仅准备以上确切范围的本方委托。Agent 提供完整授权问题后，请再次明确同意或拒绝。邀请、对方加入与实际动作会分别核验。")
    }
}

struct CollaborationActionForm: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var action = ""
    @State private var values: [String: String] = [:]
    @State private var error: String?
    @State private var confirmation: SocialConfirmation?
    @ScaledMetric(relativeTo: .body) private var textEditorHeight = 85.0
    @ScaledMetric(relativeTo: .caption) private var structuredEditorHeight = 140.0
    private var actions: [String] { store.collaborationDescription.strings("actions").filter { $0 != "describe" } }
    private var fields: RemoteRecord { store.collaborationDescription.record("action_fields").record(action) }
    private var required: [String] { fields.strings("required") }
    private var optional: [String] { fields.strings("optional") }
    private let structured = Set(["scope", "policy", "operation", "payload", "aliases"])
    private let numeric = Set(["limit", "max_chars", "after"])

    var body: some View {
        if store.available(.collaborationExecute) || store.demo {
            WorkspaceCard {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("读取本机实际开放的功能，再填写所需内容。需要授权的动作会进入确认列表。").font(.caption).foregroundStyle(.secondary)
                        Button { Task { await store.describeCollaboration(); if !actions.contains(action) { action = actions.first ?? ""; values = [:] } } } label: { Text("读取本机可用功能").workspaceTapTarget() }
                            .buttonStyle(.bordered).disabled(!store.canAct(.collaborationExecute))
                        if !actions.isEmpty {
                            Picker("选择功能", selection: $action) { ForEach(actions, id: \.self) { Text(socialActionLabel($0)).tag($0) } }.pickerStyle(.menu).workspaceTapTarget()
                                .onChange(of: action) { _, _ in values = [:]; error = nil }
                            ForEach(required + optional.filter { !required.contains($0) }, id: \.self) { field in
                                WorkspaceField(title: socialFieldLabel(field) + (required.contains(field) ? "（必填）" : "（可选）"), hint: structured.contains(field) ? "填写有效的 JSON；全文会在提交前再次展示。" : nil) {
                                    if structured.contains(field) || ["text", "query", "reference"].contains(field) {
                                        TextEditor(text: binding(field)).font(structured.contains(field) ? .system(.caption, design: .monospaced) : .body).frame(minHeight: structured.contains(field) ? structuredEditorHeight : textEditorHeight).padding(8).background(Color.listBackground, in: RoundedRectangle(cornerRadius: 10)).accessibilityLabel(socialFieldLabel(field) + (required.contains(field) ? "，必填" : "，可选"))
                                    } else { TextField(socialFieldLabel(field), text: binding(field)).crossPlatformAutocapitalization().autocorrectionDisabled().workspaceInputStyle() }
                                }
                            }
                            if let error { InlineNotice(message: error, style: .error) }
                            Button { prepare() } label: { Text("核对并执行所选功能").workspaceTapTarget() }.buttonStyle(.borderedProminent).disabled(!socialCanSubmit(store, .collaborationExecute) || action.isEmpty)
                        }
                        SocialCapabilityHint(method: .collaborationExecute)
                    }.padding(.top, 12)
                } label: { Text("更多 Agent 协作功能").frame(maxWidth: .infinity, alignment: .leading).workspaceTapTarget() }
            }.sheet(item: $confirmation) { SocialConfirmationSheet(action: $0) }
        }
    }
    private func binding(_ field: String) -> Binding<String> { Binding(get: { values[field] ?? "" }, set: { values[field] = $0 }) }
    private func prepare() {
        error = nil
        guard actions.contains(action), !fields.isEmpty else { error = "请先读取当前功能说明并选择有效功能。"; return }
        var params: RemoteRecord = ["action": .string(action)]
        for field in required + optional.filter({ !required.contains($0) }) {
            let value = (values[field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { if required.contains(field) { error = "请填写" + socialFieldLabel(field) + "。"; return }; continue }
            if structured.contains(field) {
                guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(value.utf8)) else { error = socialFieldLabel(field) + "不是有效 JSON。"; return }
                if field == "aliases" { guard decoded.arrayValue?.allSatisfy({ $0.stringValue != nil }) == true else { error = "称呼列表应为 JSON 字符串数组。"; return } }
                else { guard decoded.objectValue != nil else { error = socialFieldLabel(field) + "应为 JSON 对象。"; return } }
                params[field] = decoded
            } else if numeric.contains(field) {
                guard let number = Double(value), number.isFinite else { error = socialFieldLabel(field) + "应为有效数字。"; return }
                params[field] = .number(number)
            } else { params[field] = .string(value) }
        }
        params = socialWithSource(store, params)
        confirmation = SocialConfirmation(agentID: store.selectedAgentID, method: .collaborationExecute, params: params, title: "确认执行" + socialActionLabel(action), detail: socialPretty(params), explanation: "以下是将提交给本机 Agent 的完整内容。需要授权时只会准备确切问题；批准、实际发送、双方同步和业务完成分别核验。")
    }
}

struct SocialRecordAction: View {
    @EnvironmentObject private var store: WorkspaceStore
    let kind: String
    let recordID: String
    let title: String
    @State private var confirming = false
    private var blockedReason: String? { socialDeletionReason(store, kind: kind, id: recordID) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(role: .destructive) { confirming = true } label: { Text("从账户列表删除此记录").workspaceTapTarget() }.font(.caption).buttonStyle(.bordered)
                .disabled(store.demo || store.busy != nil || recordID.isEmpty || blockedReason != nil)
            if let blockedReason { Text(blockedReason).font(.caption2).foregroundStyle(.secondary) }
        }.confirmationDialog("删除「\(title)」的账户记录？", isPresented: $confirming, titleVisibility: .visible) {
            Button("删除账户记录", role: .destructive) { Task { await store.setRecordHidden(kind: kind, id: recordID, hidden: true) } }
            Button("取消", role: .cancel) { }
        } message: { Text("Agent 本机的记录和已发生的操作会保留。此记录将从本账户列表移除，可从「已删除记录」恢复显示。") }
    }
}

struct DeletedSocialRecordsView: View {
    @EnvironmentObject private var store: WorkspaceStore
    let kind: String
    @State private var restoring: WorkspaceRecordState?
    @State private var confirming = false
    private var records: [WorkspaceRecordState] { (store.workspace?.recordStates ?? []).filter { $0.kind == kind && $0.deleted } }
    var body: some View {
        if !records.isEmpty {
            WorkspaceCard {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(records) { record in
                            WorkspaceAdaptiveStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(record.title ?? record.id).font(.subheadline)
                                    Text("删除于 " + socialDate(.number(record.updatedAt))).font(.caption).foregroundStyle(.secondary)
                                }
                                Button { restoring = record; confirming = true } label: { Text("恢复显示").workspaceTapTarget() }.font(.caption).buttonStyle(.bordered).disabled(store.demo || store.busy != nil).accessibilityLabel("恢复显示「\(record.title ?? record.id)」")
                            }
                        }
                    }.padding(.top, 10)
                } label: { Text("已删除记录 · \(records.count)").frame(maxWidth: .infinity, alignment: .leading).workspaceTapTarget() }
            }.confirmationDialog("恢复这条账户记录？", isPresented: $confirming, titleVisibility: .visible) {
                Button("恢复显示") { if let record = restoring { Task { await store.setRecordHidden(kind: kind, id: record.id, hidden: false) } } }
                Button("取消", role: .cancel) { }
            } message: { Text(restoring?.title ?? restoring?.id ?? "") }
        }
    }
}

struct RelatedConversationLink: View {
    @EnvironmentObject private var store: WorkspaceStore
    let source: RemoteRecord
    var body: some View {
        if let verified = sourceConversation(["source_context": .object(source)]) {
            Button { Task { await store.navigateToConversation(id: verified.conversationId, turnID: verified.turnId) } } label: { Label("查看关联对话", systemImage: "bubble.left.and.bubble.right").workspaceTapTarget() }
                .font(.caption).buttonStyle(.bordered).disabled(store.busy != nil || store.demo)
        }
        if !source.isEmpty { SnapshotDetails(data: source) }
    }
}

struct SocialCapabilityHint: View {
    @EnvironmentObject private var store: WorkspaceStore
    let method: RPCMethod
    var body: some View {
        if !store.canAct(method) {
            Text(store.demo ? "演示模式不会提交操作。" : store.available(method) ? "恢复连接、完成本机配对并核实待定操作后可提交。" : "当前连接尚未开放此功能，请检查连接设置或从 Agent 原生渠道处理。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct SocialRecordRow: Identifiable {
    let id: String
    let data: RemoteRecord
}

// Business IDs preserve row identity when content changes or another record is inserted.
// Incomplete legacy records use their content; duplicate identities remain distinct.
func socialRecordRows(_ records: [RemoteRecord], key: String, fallbackKeys: [String] = [], namespaceKey: String? = nil) -> [SocialRecordRow] {
    var occurrences: [String: Int] = [:]
    return records.map { record in
        let stableKey = ([key] + fallbackKeys).first { !record.string($0).isEmpty }
        let identity = stableKey.map { $0 + ":" + record.string($0) } ?? "content:" + socialPretty(record)
        let namespace = namespaceKey.map { record.string($0) } ?? ""
        let base = namespace + ":" + identity
        let occurrence = occurrences[base, default: 0]
        occurrences[base] = occurrence + 1
        return SocialRecordRow(id: base + "#" + String(occurrence), data: record)
    }
}

@MainActor private func socialLocked(_ store: WorkspaceStore, _ method: RPCMethod, _ field: String, _ value: String) -> Bool {
    store.actionOperations.contains { $0.call.method == method && $0.call.params.string(field) == value && (method == .messagesSend ? ["sending", "uncertain"] : ["sending", "uncertain", "succeeded"]).contains($0.phase) }
}
@MainActor private func socialCanSubmit(_ store: WorkspaceStore, _ method: RPCMethod) -> Bool { store.canAct(method) && (method != .collaborationExecute || !store.uncertainActions.contains { $0.call.method == .collaborationExecute }) }
@MainActor private func socialDeletionReason(_ store: WorkspaceStore, kind: String, id: String) -> String? {
    if store.submission != nil || !store.uncertainActions.isEmpty { return "先核实尚未确认的操作，再删除账户记录。" }
    let data = store.collaboration
    let approvals = data.records("pending_confirmations").filter { ["pending", "presenting", "expired"].contains($0.string("status")) }
    if kind == "contact" {
        let contact = store.contacts.first { $0.string("contact_id") == id } ?? [:]
        let urn = contact.string("urn")
        if ["pending", "requested"].contains(contact.string("connection_status")) || store.contactRequests.contains(where: { ($0.string("contact_id") == id || !urn.isEmpty && [$0.string("peer_urn"), $0.string("urn"), $0.string("sender_urn"), $0.string("recipient_urn")].contains(urn)) && ["pending", "requested", "sending"].contains($0.string("status")) }) { return "好友申请仍待处理，处理结束后可删除账户记录。" }
        if approvals.contains(where: { [id, urn].contains($0.string("subject_id")) || $0.string("contact_id") == id || $0.record("target").string("id") == id }) { return "先处理这个联系人的待确认请求。" }
        return nil
    }
    let view = data["collaborations"]?.arrayValue != nil ? data : data["collaboration"]?.objectValue ?? data.record("collaboration_v2")
    let collaborations = view.records("collaborations")
    let record = collaborations.first { $0.string("collaboration_id") == id || $0.string("task_id") == id }
    let taskID = record?.string("task_id", default: id) ?? id
    let linked = collaborations.filter { $0.string("task_id") == taskID || $0.string("collaboration_id") == id }
    var ids = Set([id, taskID] + linked.map { $0.string("collaboration_id") })
    for operation in data.records("operations") + view.records("operations") where ids.contains(operation.string("task_id")) || ids.contains(operation.string("collaboration_id")) { ids.insert(operation.string("operation_id")) }
    if approvals.contains(where: { ids.contains($0.string("subject_id")) || ids.contains($0.string("task_id")) || ids.contains($0.record("target").string("id")) }) { return "先处理这件协作的待确认请求。" }
    if !linked.isEmpty {
        if linked.contains(where: { $0.string("phase") != "closed" || $0.bool("withdraw_pending") || !["cancelled", "withdrawn", "expired", "agreement_only_complete"].contains($0.string("closure_reason")) || $0.string("closure_reason") == "agreement_only_complete" && !$0.bool("agreement_synced") }) { return "协作仍在进行或结果待核实，结束后可删除账户记录。" }
    } else if !data.records("tasks").contains(where: { $0.string("task_id") == taskID && ["revoked", "completed", "cancelled", "expired", "denied", "rejected"].contains($0.string("status")) }) { return "协作仍在进行或状态待核实，结束后可删除账户记录。" }
    return nil
}
@MainActor private func socialWithSource(_ store: WorkspaceStore, _ params: RemoteRecord) -> RemoteRecord {
    let support = store.collaborationDescription.record("source_context_support")
    guard support.number("version") == 1, support.string("rpc_param") == "source_conversation_id", isStableID(store.conversationID) else { return params }
    var result = params; result["source_conversation_id"] = .string(store.conversationID); return result
}
func socialContactName(_ contact: RemoteRecord) -> String { contact.strings("aliases").first(where: { !$0.isEmpty }) ?? (contact.string("alias").isEmpty ? contact.string("contact_id", default: "联系人") : contact.string("alias")) }
func peerContentApproved(_ record: RemoteRecord) -> Bool { record.record("content_review").string("status") == "approved" }
func socialValidUrn(_ value: String) -> Bool { value.count <= 256 && value.range(of: "^urn:[A-Za-z0-9][A-Za-z0-9._:-]*:[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil }
func socialRemoteDate(_ value: JSONValue?) -> Date? {
    if let seconds = value?.numberValue, seconds.isFinite { return Date(timeIntervalSince1970: seconds < 1_000_000_000_000 ? seconds : seconds / 1000) }
    guard let text = value?.stringValue else { return nil }
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
}
func socialDate(_ value: JSONValue?) -> String { socialRemoteDate(value)?.formatted(date: .abbreviated, time: .shortened) ?? "" }
func socialPretty(_ value: RemoteRecord) -> String { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
func socialScalar(_ value: JSONValue?) -> String { if let text = value?.stringValue { return text }; if let number = value?.numberValue { return number.formatted() }; return "未提供" }
func socialMessageText(_ text: String) -> String {
    if let data = text.data(using: .utf8), let record = try? JSONDecoder().decode(RemoteRecord.self, from: data), record.string("protocol") == "agent-comm-collaboration/v1", !record.string("text").isEmpty { return record.string("text") }
    return text.isEmpty ? "这条消息未提供文本内容。" : text
}
func socialSentStatus(_ status: String) -> String { status == "accepted" ? "本机已受理，尚不能证明对方已读" : status == "queued" ? "等待投递" : stateText(status) }
func socialCapabilityLabel(_ value: String) -> String { ["share_slots": "分享候选时段", "share_resource": "分享所选资料全文", "propose_meeting": "提出会议方案", "accept_meeting": "接受范围内会议方案", "send_text": "逐次核对后发送文本"][value] ?? value }
func socialOperationLabel(_ operation: RemoteRecord) -> String { ["invite": "邀请对方加入", "join": "加入此协作", "proposal": "提出会议方案", "change_request": "调整会议方案", "accept": "接受当前会议方案", "withdraw": "撤回自己的接受", "cancel_request": "请求取消双方约定", "cancel_ack": "同意取消双方约定"][operation.string("kind")] ?? socialCapabilityLabel(operation.record("action").string("capability", default: "协作动作")) }
func socialWaitingLabel(_ value: String) -> String { ["agreement_sync": "等待对方核对约定", "agreement_ack": "等待约定同步回执", "agreement_ack_delivery": "同步回执正在投递", "missing_event": "正在补齐缺失事件", "withdrawal_decision": "撤回结果需要核实", "cancel_decision": "等待取消决定", "maintenance_permission": "需要本人续期或调整后续同步权限", "maintenance_budget": "后续同步预算已用尽，需要本人决定", "event_chain_conflict": "双方事件记录存在冲突，需要核对", "owner_decision": "等待本人决定", "peer_join": "等待对方加入", "peer_accept": "等待对方接受"][value] ?? "仍有协作状态待核对：" + value }
func socialActionLabel(_ value: String) -> String { ["state": "查看协作状态", "collaborations": "查看协作记录", "attention": "查看待处理提醒", "inbox": "查看收件箱", "prepare_collaboration": "创建协作提议", "revoke_collaboration_maintenance": "停止协作维护", "import_proposal": "导入协作提议", "register_resource": "添加可分享资料", "resolve_contact": "查找联系人", "export_contact": "分享联系人信息", "prepare_contact": "准备联系人授权", "prepare_task": "创建协作事项", "prepare_worker_policy": "设置自动协作范围", "pause_worker": "暂停自动协作", "revoke_worker": "撤销自动协作", "prepare_action": "准备协作动作", "confirm": "查看授权结果", "dispatch": "执行已授权动作", "revoke": "撤销事项", "memory_search": "搜索本机记忆", "memory_snapshot": "查看记忆内容", "snapshot_resource": "创建记忆资料", "prepare_message": "准备消息", "send_message": "发送消息", "contact_requests": "查看好友请求", "prepare_contact_response": "回应好友请求", "mark_read": "将消息标为已读"][value] ?? value }
func socialFieldLabel(_ value: String) -> String { ["task_id": "事项 ID", "collaboration_id": "协作 ID", "operation_id": "动作 ID", "resource_id": "资料 ID", "approval_id": "授权 ID", "message_id": "消息 ID", "request_id": "请求 ID", "contact_id": "联系人 ID", "recipient_urn": "接收者 URN", "urn": "URN", "aliases": "称呼列表", "title": "标题", "text": "内容", "name": "姓名或称呼", "scope": "协作范围", "policy": "执行规则", "operation": "协作动作内容", "payload": "提议内容", "kind": "提议类型", "query": "搜索内容", "reference": "资料引用", "limit": "数量", "max_chars": "最多字符数", "after": "提醒游标", "platform_url": "平台地址"][value] ?? value }
