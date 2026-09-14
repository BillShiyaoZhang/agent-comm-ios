import SwiftUI

struct AddConnectionView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var urn = ""
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    WorkspaceField(title: "连接名称") { TextField("例如：我的 Hermes", text: $name).textContentType(.nickname) }
                    WorkspaceField(title: "Agent URN", hint: "在运行 Agent 的设备上查看完整身份标识。") {
                        TextField("urn:agent:…", text: $urn, axis: .vertical).crossPlatformAutocapitalization().autocorrectionDisabled().font(.system(.body, design: .monospaced))
                    }
                } header: { Text("连接你的 Agent") } footer: { Text("保存后，需要在 Agent 本机为你的控制台授权，才能读取数据或发送消息。") }
                if let error { Section { InlineNotice(message: error, style: .error) } }
                Section {
                    Button {
                        saving = true; error = nil
                        Task {
                            do { try await store.addConnection(name: name, urn: urn); dismiss() }
                            catch { self.error = error.localizedDescription }
                            saving = false
                        }
                    } label: {
                        HStack { if saving { ProgressView() }; Text(saving ? "正在验证连接…" : "保存连接").frame(maxWidth: .infinity) }
                    }.disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 100 || urn.trimmingCharacters(in: .whitespacesAndNewlines).count < 10 || urn.count > 256)
                }
            }.formStyle(.grouped).disabled(saving)
                .navigationTitle("添加连接")
                .crossPlatformNavigationBarTitleDisplayModeInline()
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) } }
        }.interactiveDismissDisabled(saving).frame(minWidth: 300, idealWidth: 520, minHeight: 420)
    }
}

struct PairingView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var expanded = false
    var body: some View {
        if let workspace = store.workspace {
            WorkspaceCard {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("完成一次本机配对，之后各端可接续同一个工作空间。").font(.subheadline).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 10) {
                            Label("1 · 控制台身份", systemImage: "person.crop.circle.badge.checkmark").font(.subheadline.bold())
                            if let urn = workspace.identity.virtualUrn {
                                Text(urn).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                CopyLabel(value: urn, title: "复制控制台 URN")
                            } else {
                                Button("创建控制台身份") { Task { await store.bindIdentity() } }.buttonStyle(.borderedProminent).disabled(store.busy != nil || store.demo)
                            }
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 10) {
                            Label("2 · 在 Agent 本机授权", systemImage: "key").font(.subheadline.bold())
                            Text("将控制台 URN 添加到本机配对记录与允许列表，并保持 Agent 和 helper 运行。授权的功能会在连接检查后显示。").font(.subheadline).foregroundStyle(.secondary)
                            Link("查看安装与配对说明", destination: URL(string: "https://agent-communication.online/docs/")!).font(.subheadline)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 10) {
                            Label("3 · 验证连接", systemImage: "checkmark.shield").font(.subheadline.bold())
                            Button { Task { await store.invoke(.capabilities) } } label: { Label("检查连接与权限", systemImage: "arrow.triangle.2.circlepath") }.buttonStyle(.borderedProminent).disabled(workspace.identity.virtualUrn == nil || store.busy != nil || store.demo)
                            if let capabilities = store.capabilities {
                                ForEach(Array(capabilities.records("methods").enumerated()), id: \.offset) { _, method in
                                    HStack(alignment: .top) {
                                        Image(systemName: method.bool("available") ? "checkmark.circle.fill" : "minus.circle").foregroundStyle(method.bool("available") ? Color.statusSuccess : .secondary)
                                        Text(methodTitle(method.string("name"))).font(.caption)
                                        Spacer()
                                        Text(method.bool("available") ? "已开放" : "未开放").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        DisclosureGroup("连接详情") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Agent URN").font(.caption.bold())
                                Text(workspace.agent.urn).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                CopyLabel(value: workspace.agent.urn, title: "复制 Agent URN")
                                if let key = workspace.identity.virtualEd25519PublicKey { Text("控制台验证公钥").font(.caption.bold()); Text(key).font(.system(.caption, design: .monospaced)).textSelection(.enabled); CopyLabel(value: key, title: "复制公钥") }
                                Button("重新注册控制台身份") { Task { await store.bindIdentity() } }.font(.caption).disabled(store.busy != nil || store.demo)
                            }.padding(.top, 10)
                        }.font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 18)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: store.capabilities == nil || workspace.sync.status == "needs_pairing" ? "key.fill" : "checkmark.shield.fill").foregroundStyle(Color.brandPrimary)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(store.capabilities == nil ? "完成连接设置" : "连接与权限").font(.subheadline.bold())
                            SyncStatusView(sync: workspace.sync)
                        }
                    }
                }
            }.onAppear { expanded = store.capabilities == nil || workspace.sync.status == "needs_pairing" }
                .onChange(of: workspace.agent.id) { _, _ in expanded = store.capabilities == nil || workspace.sync.status == "needs_pairing" }
        }
    }
    private func methodTitle(_ name: String) -> String {
        ["capabilities": "检查连接", "contacts.list": "联系人", "collaboration.state": "协作进展", "inbox.list": "收件箱", "conversation.send": "发送消息", "conversation.get": "读取对话", "approval.respond": "远程确认（请在原生渠道处理）"][name] ?? name
    }
}
