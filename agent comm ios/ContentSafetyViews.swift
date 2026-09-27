import SwiftUI
import AgentWorkspaceKit

/// This invokes the paired Agent's persistent safety controls; saved-view hiding is separate.
struct PeerSafetyControls: View {
    @EnvironmentObject private var store: WorkspaceStore
    let urn: String
    @State private var confirmation: SocialConfirmation?

    private var blocked: Bool { store.peerIsBlocked(urn) }
    private var method: RPCMethod { blocked ? .contactsUnblock : .contactsBlock }

    var body: some View {
        if socialValidUrn(urn) {
            VStack(alignment: .leading, spacing: 8) {
                if blocked { Label("此发送方已被 Agent 屏蔽", systemImage: "hand.raised.fill").font(.caption).foregroundStyle(Color.statusWarning) }
                Button(role: blocked ? nil : .destructive) {
                    confirmation = SocialConfirmation(agentID: store.selectedAgentID, method: method, params: ["urn": .string(urn)],
                        title: blocked ? "确认解除屏蔽" : "确认屏蔽发送方", detail: "发送方 URN：\n" + urn,
                        explanation: blocked
                            ? "解除后，这个 Agent 可以接收并按权限处理新的业务消息。过去被阻断的消息不会自动恢复；这项决定不会授予新的好友或协作权限。"
                            : "这个 Agent 将持久阻止此发送方的业务消息展示、模型处理与后续排队发送。平台和连接助手仍可能收取信封。已经派发的内容无法召回；其他 Agent 和工作区需要分别管理。")
                } label: { Label(blocked ? "解除屏蔽" : "屏蔽此发送方", systemImage: blocked ? "hand.raised.slash" : "hand.raised").workspaceTapTarget() }
                    .font(.caption).buttonStyle(.bordered)
                    .disabled(!store.canAct(method) || store.peerSafetyPending(urn))
                if store.peerSafetyPending(urn) {
                    Text("屏蔽操作结果待核实，请刷新或查看原请求。").font(.caption).foregroundStyle(Color.statusWarning)
                } else if !store.available(method) {
                    Text("此 Agent 尚未开放这项安全能力。请升级 Agent 并在其设备上明确授权；隐藏记录只改变账户中的显示。").font(.caption).foregroundStyle(.secondary)
                }
            }.sheet(item: $confirmation) { SocialConfirmationSheet(action: $0) }
        }
    }
}

struct BlockedPeersView: View {
    @EnvironmentObject private var store: WorkspaceStore
    var body: some View {
        if !store.blockedPeers.isEmpty {
            WorkspaceCard {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(socialRecordRows(store.blockedPeers, key: "urn")) { row in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(row.data.string("urn")).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                PeerSafetyControls(urn: row.data.string("urn"))
                            }
                        }
                    }.padding(.top, 10)
                } label: { Text("已屏蔽发送方 · \(store.blockedPeers.count)").frame(maxWidth: .infinity, alignment: .leading).workspaceTapTarget() }
            }
        }
    }
}

/// Unreviewed peer text is reviewed on the authenticated website before App display.
struct PendingContentReview: View {
    @EnvironmentObject private var store: WorkspaceStore
    let messageID: String
    var status = "pending"
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(status == "rejected" ? "此内容未获准显示" : "对端内容待审核", systemImage: "eye.slash").font(.subheadline)
            Text(status == "rejected" ? "这项内容保持隐藏；如有疑问，可以查看审核状态或联系工作区。" : "正文审核通过后才会显示；审批与数据共享许可仍需分别确认。").font(.caption).foregroundStyle(.secondary)
            if let link = reviewURL {
                Link(destination: link) { Label(status == "rejected" ? "在网站查看审核状态" : "在工作区网站审核内容", systemImage: "safari").workspaceTapTarget() }.font(.caption)
            }
        }
    }
    private var reviewURL: URL? {
        guard let context = store.sharingContext, var url = URLComponents(string: context.server), isStableID(messageID) else { return nil }
        url.path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/dashboard/content-review"
        if !url.path.hasPrefix("/") { url.path = "/" + url.path }
        url.queryItems = [URLQueryItem(name: "agentId", value: context.agentID), URLQueryItem(name: "messageId", value: messageID)]
        url.fragment = nil
        return url.url
    }
}
