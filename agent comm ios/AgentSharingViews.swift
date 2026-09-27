import SwiftUI

struct AgentSharingDisclosure: View {
    let context: AgentSharingContext

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("内容交给谁处理").font(.headline).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 4) {
                Text("工作区").font(.caption).foregroundStyle(.secondary)
                Text(context.server).textSelection(.enabled)
                Text("你的 Agent").font(.caption).foregroundStyle(.secondary)
                Text(context.agentName).font(.subheadline.bold())
                Text(context.agentURN).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            Text("你发送的消息、对话上下文、联系人信息和协作内容会经此工作区交给以上 Agent。它可能按照你自行配置的模型与工具处理或转发这些内容；协作时还可能向你在具体操作中确认的接收方分享。")
            Text("请核对这个 Agent 的模型与工具配置。本应用无法列出或核验其具体服务供应商，也无法发现其配置变化。配置改变时，请撤回本许可并重新核对。")
            Text("许可仅用于本应用当前登录会话中的此 Agent；重新登录、重启应用或切换 Agent 后需要重新同意。你可以拒绝或随时撤回，仍可阅读已有内容。撤回会停止本应用当前会话的新发送和重试；Web、其他设备和 Agent 本机的授权需要分别管理。已派发的请求与已分享的内容无法通过此操作撤回。")
        }
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Independent from confirmation of a business action's exact contents and recipient.
struct AgentSharingConsentControl: View {
    @EnvironmentObject private var store: WorkspaceStore
    let context: AgentSharingContext

    var body: some View {
        Toggle("允许本次会话向以上 Agent 共享内容，并由我配置的模型与工具处理", isOn: Binding(
            get: { store.hasAgentSharingPermission && store.sharingPermission == context },
            set: { allowed in
                if allowed { store.allowAgentSharing(context) }
                else if store.sharingPermission == context { store.revokeAgentSharing() }
            }))
            .font(.subheadline)
            .disabled(store.sharingContext != context)
            .accessibilityHint("独立的内容共享许可。关闭后停止本应用当前会话的新发送和重试。")
    }
}

struct AgentSharingPermissionView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let context: AgentSharingContext

    private var current: Bool { store.sharingContext == context }
    private var allowed: Bool { current && store.hasAgentSharingPermission }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    AgentSharingDisclosure(context: context)
                    if !current {
                        InlineNotice(message: "当前账户或 Agent 已变化，请关闭后重新查看共享范围。", style: .error)
                    } else if allowed {
                        InlineNotice(message: "此 Agent 已获得本次会话的内容共享许可。", style: .info)
                        Button(role: .destructive) {
                            store.revokeAgentSharing()
                            dismiss()
                        } label: { Text("撤回共享许可").frame(maxWidth: .infinity).workspaceTapTarget() }
                            .buttonStyle(.bordered)
                    } else {
                        Text("同意后返回原页面，由你再次点按发送或确认操作。此页不会向 Agent 派发内容。")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button {
                            if store.allowAgentSharing(context) { dismiss() }
                        } label: { Text("同意共享并返回").frame(maxWidth: .infinity).workspaceTapTarget() }
                            .buttonStyle(WorkspacePrimaryButtonStyle())
                    }
                }.padding(20)
            }
            .background(Color.listBackground)
            .navigationTitle("管理共享授权")
            .crossPlatformNavigationBarTitleDisplayModeInline()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .frame(minWidth: 300, idealWidth: 540, minHeight: 420)
    }
}
