import SwiftUI
import AgentWorkspaceKit

struct AgentAvatar: View {
    let name: String
    var size: CGFloat = 46
    var body: some View {
        Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .frame(width: size, height: size).foregroundStyle(Color.brandPrimary)
            .background(Color.brandPrimary.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.3))
            .accessibilityHidden(true)
    }
}

struct SyncStatusView: View {
    let sync: WorkspaceSync
    var body: some View {
        Label(syncText(sync.status), systemImage: syncIcon(sync.status))
            .font(.caption).foregroundStyle(syncColor(sync.status))
            .accessibilityLabel("同步状态：" + syncText(sync.status))
    }
}
func syncText(_ status: String) -> String {
    switch status { case "ready": return "已同步"; case "syncing": return "正在同步"; case "offline": return "暂未连接 · 保留已同步内容"; case "needs_pairing": return "需要本机配对"; default: return "等待同步" }
}
func syncIcon(_ status: String) -> String {
    switch status { case "ready": return "checkmark.circle.fill"; case "syncing": return "arrow.triangle.2.circlepath"; case "offline": return "wifi.slash"; case "needs_pairing": return "key.fill"; default: return "clock" }
}
func syncColor(_ status: String) -> Color {
    switch status { case "ready": return .statusSuccess; case "offline", "needs_pairing": return .statusWarning; default: return .secondary }
}
func remoteDate(_ value: JSONValue?) -> String {
    guard let value else { return "" }
    let date: Date?
    switch value {
    case .number(let seconds): date = Date(timeIntervalSince1970: seconds)
    case .string(let text):
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        date = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    default: date = nil
    }
    return date?.formatted(date: .abbreviated, time: .shortened) ?? ""
}
func stateText(_ status: String) -> String {
    ["submitted": "等待处理", "running": "处理中", "completed": "本回合已完成", "failed": "处理失败", "interrupted": "结果待核实", "pending": "待确认", "presenting": "等待本机确认", "expired": "已过期", "active": "已授权", "revoked": "已撤销", "ready": "准备发送", "sending": "正在投递", "accepted": "本机队列已接收", "awaiting_approval": "待确认", "denied": "已拒绝", "approved": "已确认"][status] ?? (status.isEmpty ? "状态未知" : status)
}
struct RemoteStatus: View {
    let status: String
    var body: some View { StatusBadge(text: stateText(status), color: color) }
    private var color: Color {
        if ["completed", "active", "approved"].contains(status) { return .statusSuccess }
        if ["failed", "interrupted", "denied", "revoked", "expired"].contains(status) { return .statusDestructive }
        return .statusWarning
    }
}
struct WorkspaceFeedback: View {
    @EnvironmentObject private var store: WorkspaceStore
    var body: some View {
        VStack(spacing: 8) {
            if store.demo { InlineNotice(message: "界面演示 · 使用示例数据", style: .info) }
            if let message = store.connectionError { InlineNotice(message: message, style: .error) }
            if let error = store.error {
                InlineNotice(message: error, style: .error)
                Button("重新连接") { Task { await store.refresh(schedule: true) } }.font(.subheadline).disabled(store.busy != nil)
            }
            if store.busy != nil { ProgressView(store.busy == "conversation.send" ? "等待 Agent 受理…" : "正在更新…").font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }
}
struct AgentPicker: View {
    @EnvironmentObject private var store: WorkspaceStore
    var body: some View {
        Menu {
            ForEach(store.connections) { agent in Button { Task { await store.selectAgent(agent.id) } } label: { Label(agent.name, systemImage: agent.id == store.selectedAgentID ? "checkmark.circle" : "circle") } }
        } label: {
            HStack(spacing: 10) {
                AgentAvatar(name: store.selectedAgent?.name ?? "A", size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.selectedAgent?.name ?? "选择 Agent").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    if let sync = store.workspace?.sync { SyncStatusView(sync: sync) }
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
            }.padding(12).background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 16))
        }.disabled(store.busy != nil || store.connections.isEmpty).accessibilityLabel("切换 Agent")
    }
}
struct CopyLabel: View {
    let value: String
    var title = "复制"
    @State private var copied = false
    var body: some View {
        Button { Clipboard.copy(text: value); copied = true } label: { Label(copied ? "已复制" : title, systemImage: copied ? "checkmark" : "doc.on.doc") }
            .font(.caption).buttonStyle(.bordered).accessibilityLabel(copied ? "已复制" : title)
            .task(id: copied) { if copied { try? await Task.sleep(for: .seconds(2)); copied = false } }
    }
}
struct SnapshotDetails: View {
    let data: RemoteRecord
    var body: some View {
        DisclosureGroup("技术详情") {
            Text(pretty).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        }.font(.caption).foregroundStyle(.secondary)
    }
    private var pretty: String { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return (try? encoder.encode(data)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
}
