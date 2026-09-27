import SwiftUI
import AgentWorkspaceKit

struct PolicyDisclosureView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var expanded = false
    @State private var accepted = false
    var body: some View {
        if !store.demo {
            WorkspaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    if let policy = store.policy {
                        let access = policy.bool("can_use_workbench")
                        let compliance = policy.string("mode") == "compliance"
                        Label(access ? "平台政策与内容可见范围" : policy.bool("paused") ? "远程控制与同步已暂停" : "请确认平台政策", systemImage: access ? "checkmark.shield" : "hand.raised")
                            .font(.subheadline.bold())
                        Text(policy.string("status") == "legacy" ? "平台尚无可验证的 v2 签名政策；工作区服务可读取经授权的控制内容。" : compliance ? "平台网关可解密符合合规政策的 agent 间 v2 消息；工作区服务可读取经授权的控制内容。" : "平台网关不获 v2 私密消息内容密钥；工作区服务可读取经授权的控制内容。")
                            .font(.caption).foregroundStyle(.secondary)
                        if !access || expanded {
                            if policy.string("status") == "signed" {
                                Text("已验证政策：\(compliance ? "合规模式" : "隐私模式") · epoch \(Int(policy.number("epoch"))) · 平台 \(policy.string("platform_id"))").font(.caption).textSelection(.enabled)
                                if compliance { Text("网关密钥 ID：" + policy.string("gateway_key_id")).font(.caption).textSelection(.enabled) }
                                Text("此处展示平台政策，不证明某条消息的实际发送模式。托管控制通道与平台网关具有不同的内容可见范围。").font(.caption).foregroundStyle(.secondary)
                            }
                            if compliance && !policy.bool("confirmed") {
                                Toggle("我已了解平台网关与工作区服务的上述内容可见范围", isOn: $accepted).font(.subheadline)
                                Button { Task { await store.changePolicy("confirm", displayedHash: policy.string("policy_hash")) } } label: { Text("确认并继续使用").workspaceTapTarget() }.buttonStyle(.borderedProminent).disabled(!accepted || store.busy != nil)
                            }
                            if policy.bool("paused") {
                                Text("历史仍可查看。暂停不会收回已披露内容；停止 Agent 披露或撤销工作区访问，仍需在 Agent 所在设备分别设置。").font(.caption).foregroundStyle(.secondary)
                                if policy.string("status") == "legacy" || !compliance || policy.bool("confirmed") {
                                    Button { Task { await store.changePolicy("resume") } } label: { Text("恢复远程控制与同步").workspaceTapTarget() }.buttonStyle(.bordered).disabled(store.busy != nil)
                                }
                            } else {
                                Button { Task { await store.changePolicy("pause") } } label: { Text(access ? "暂停后续远程控制与同步" : "暂不接受并暂停").workspaceTapTarget() }.buttonStyle(.bordered).disabled(store.busy != nil)
                            }
                        }
                        if access {
                            Button { expanded.toggle() } label: { Text(expanded ? "收起详情" : "查看详情与控制").workspaceTapTarget() }
                                .font(.caption).accessibilityValue(expanded ? "已展开" : "已收起")
                        }
                    } else {
                        Label("正在核验平台政策", systemImage: "shield").font(.subheadline.bold())
                        Text(store.policyError ?? "核验前暂停远程控制与同步，已保存内容仍可查看。").font(.caption).foregroundStyle(.secondary)
                        if store.policyError != nil { Button { Task { await store.refreshPolicy() } } label: { Text("重新核验").workspaceTapTarget() }.buttonStyle(.bordered).disabled(store.busy != nil) }
                    }
                }
            }.onChange(of: store.policy?.string("policy_hash")) { _, _ in accepted = false }
        }
    }
}

struct NotificationsView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    WorkspaceFeedback()
                    Text("未读 \(Int(store.notificationCounts.number("unread"))) · 待处理 \(Int(store.notificationCounts.number("pending")))").font(.subheadline).foregroundStyle(.secondary)
                    if dynamicTypeSize.isAccessibilitySize { filterPicker.pickerStyle(.menu) }
                    else { filterPicker.pickerStyle(.segmented) }
                    if let error = store.notificationError { InlineNotice(message: error, style: .error) }
                    if store.notifications.isEmpty { EmptyState(title: "暂时没有提醒", message: "需要你决定的事项、收到的消息和对话结果会显示在这里。", systemImage: "bell") }
                    ForEach(store.notifications.map { NotificationCardItem(data: $0) }) { record in
                        let item = record.data
                        WorkspaceCard {
                            VStack(alignment: .leading, spacing: 12) {
                                WorkspaceAdaptiveStack {
                                    Text(item.string("title", default: "Agent 提醒")).font(.headline).fixedSize(horizontal: false, vertical: true)
                                        .accessibilityAddTraits(.isHeader).accessibilityValue(item.bool("unread") ? "未读" : "已读")
                                    RemoteStatus(status: item.string("state"))
                                }
                                Text(item.string("summary")).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                WorkspaceAdaptiveStack(spacing: 8) {
                                    Text(item.string("agentName"))
                                    Text(Date(timeIntervalSince1970: item.number("updatedAt") / 1000), style: .relative)
                                        .accessibilityLabel("更新时间")
                                        .accessibilityValue(Date(timeIntervalSince1970: item.number("updatedAt") / 1000).formatted(date: .abbreviated, time: .shortened))
                                }.font(.caption).foregroundStyle(.secondary)
                                WorkspaceAdaptiveStack {
                                    Button { Task { await store.openNotification(item) } } label: { Text("查看原内容").workspaceTapTarget() }.buttonStyle(.borderedProminent)
                                        .accessibilityLabel("查看「\(item.string("title", default: "Agent 提醒"))」原内容")
                                    if item.bool("unread") {
                                        Button { Task { await store.markNotificationRead(item) } } label: { Text("标记已读").workspaceTapTarget() }.buttonStyle(.bordered)
                                            .accessibilityLabel("将「\(item.string("title", default: "Agent 提醒"))」标记已读")
                                    }
                                }.disabled(store.busy != nil || store.demo)
                            }
                        }
                    }
                    if store.notificationBefore != nil { Button { Task { await store.refreshNotifications(earlier: true) } } label: { Text("加载更早提醒").frame(maxWidth: .infinity).workspaceTapTarget() } }
                    Text("标记已读不会批准请求。消息已读须由 Agent 确认；当前原生客户端在打开时更新提醒，后台推送尚未接入。").font(.caption).foregroundStyle(.secondary)
                }.padding(20).frame(maxWidth: 820).frame(maxWidth: .infinity)
            }.background(Color.listBackground).navigationTitle("提醒")
                .refreshable { await store.refreshNotifications() }
                .onChange(of: store.notificationFilter) { _, _ in Task { await store.refreshNotifications() } }
        }
    }

    private var filterPicker: some View {
        Picker("筛选提醒", selection: $store.notificationFilter) {
            Text("全部").tag("all"); Text("未读").tag("unread"); Text("待处理").tag("pending")
        }
    }
}

private struct NotificationCardItem: Identifiable {
    let data: RemoteRecord
    var id: String { data.string("agentId") + ":" + data.string("id") }
}

struct ConnectionManagementView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var removing = false
    @FocusState private var editingName: Bool
    var body: some View {
        NavigationStack {
            Form {
                Section("连接名称") {
                    TextField("名称", text: $name).focused($editingName).submitLabel(.done).onSubmit { editingName = false }
                    Button("保存名称") { editingName = false; Task { await store.manageConnection(name: name.trimmingCharacters(in: .whitespacesAndNewlines)); if store.error == nil { dismiss() } } }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 120 || store.busy != nil || store.demo)
                }
                Section {
                    Text(store.selectedAgent?.urn ?? "").font(.caption.monospaced()).textSelection(.enabled)
                    Button("移除账户连接", role: .destructive) { removing = true }.disabled(store.busy != nil || store.submission != nil || !store.uncertainActions.isEmpty || store.demo)
                } footer: { Text("移除会删除此账户保存的连接和同步副本。Agent 本机配对与正在执行的动作需另行处理。") }
                if let error = store.error { InlineNotice(message: error, style: .error) }
            }.workspaceScrollDismissesKeyboard()
                .navigationTitle("管理连接").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(store.busy != nil) } }
                .onAppear { name = store.selectedAgent?.name ?? "" }
                .confirmationDialog("移除连接及此账户中的同步副本？", isPresented: $removing, titleVisibility: .visible) {
                    Button("移除账户连接", role: .destructive) { Task { await store.manageConnection(remove: true); if store.error == nil { dismiss() } } }
                } message: { Text("这会删除账户历史副本。不会撤销 Agent 本机配对、取消已执行的动作或删除本机记录。") }
        }.interactiveDismissDisabled(store.busy != nil).frame(minWidth: 300, idealWidth: 520, minHeight: 400)
    }
}

struct OnboardingClaimView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var code = ""
    @State private var preview: RemoteRecord?
    @State private var error: String?
    @State private var busy = false
    @State private var accepted = false
    @FocusState private var enteringLink: Bool
    private let network = NetworkManager.shared
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("粘贴一次性连接链接或连接码", text: $link, axis: .vertical).lineLimit(1...4).autocorrectionDisabled().crossPlatformAutocapitalization().focused($enteringLink)
                        .accessibilityLabel("一次性连接链接或连接码")
                    Button("读取连接请求") { Task { await readPreview() } }.disabled(busy || store.demo || link.isEmpty)
                } header: { Text("从 Agent 所在设备获取链接") } footer: { Text("运行新版连接脚本，将生成的 /connect/ 链接粘贴到这里。链接必须属于当前工作区。") }
                if let preview {
                    Section("核对授权范围") {
                        Text(preview.string("name")).font(.headline)
                        Text(preview.string("agent_urn")).font(.caption.monospaced()).textSelection(.enabled)
                        ForEach(preview.strings("methods"), id: \.self) { Text($0).font(.caption) }
                        Text("配对到期：" + remoteDate(preview["expires_at"])).font(.caption)
                        Text("链接到期：" + remoteDate(preview["ticket_expires_at"])).font(.caption)
                        if preview.string("status") == "pending" {
                            Toggle("允许此账户在上述范围和期限内访问这个 Agent", isOn: $accepted)
                            Button("确认连接与授权") { Task { await approve() } }.disabled(!accepted || busy || !store.policyAccess || store.demo)
                        } else {
                            Label(preview.string("status") == "completed" ? "Agent 已完成配对" : "账户已授权，等待 Agent 保存配对", systemImage: preview.string("status") == "completed" ? "checkmark.circle" : "clock")
                            Button("检查完成状态") { Task { await readPreview() } }.disabled(busy)
                        }
                    }
                }
                if let error { InlineNotice(message: error, style: .error) }
                if !store.policyAccess { Text("请先在工作台核验并确认平台政策。").foregroundStyle(Color.statusWarning) }
                if busy { ProgressView("正在处理…") }
            }.workspaceScrollDismissesKeyboard()
                .navigationTitle("通过链接连接 Agent")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(busy) }
                    #if os(iOS)
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("完成输入") { enteringLink = false }
                    }
                    #endif
                }
        }.interactiveDismissDisabled(busy).frame(minWidth: 300, idealWidth: 540, minHeight: 500)
    }
    private func readPreview() async {
        enteringLink = false
        busy = true; error = nil; defer { busy = false }
        do {
            let input = link.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate: String
            if let url = URL(string: input), url.scheme != nil {
                guard let base = URL(string: network.baseUrl), url.scheme == base.scheme, url.host == base.host, url.port == base.port,
                      url.path.hasPrefix("/connect/"), url.pathComponents.count == 3 else { throw WorkspaceClientError.custom("连接链接必须属于当前工作区，且路径为 /connect/连接码。") }
                candidate = url.lastPathComponent
            } else { candidate = input }
            let value = try await network.previewOnboarding(code: candidate)
            guard !Task.isCancelled else { return }
            if candidate != code || preview?.string("agent_urn") != value.string("agent_urn") || preview?.strings("methods") != value.strings("methods") { accepted = false }
            code = candidate; preview = value
            if value.string("status") == "completed" { await store.refresh(); if !value.string("agent_id").isEmpty { await store.selectAgent(value.string("agent_id")) } }
        } catch { self.error = error.localizedDescription }
    }
    private func approve() async {
        guard accepted, let shown = preview, shown.string("status") == "pending" else { return }
        busy = true; error = nil; defer { busy = false }
        do {
            let fresh = try await network.previewOnboarding(code: code)
            guard fresh.string("agent_urn") == shown.string("agent_urn"), fresh.strings("methods") == shown.strings("methods"), fresh["expires_at"] == shown["expires_at"] else { preview = fresh; accepted = false; throw WorkspaceClientError.custom("授权范围已变化，请重新核对。") }
            preview = try await network.approveOnboarding(code: code); accepted = false
            await store.refresh()
        } catch { self.error = error.localizedDescription }
    }
}
