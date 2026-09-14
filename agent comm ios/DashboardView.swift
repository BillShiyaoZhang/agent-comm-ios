import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var showSettings = false
    @State private var showConnect = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("让协作，继续向前。").font(.title2.weight(.semibold))
                        Text("连接你的 Agent，在这里接续对话、掌握进展。").font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.top, 6)
                    WorkspaceFeedback()
                    if store.isLoading { ProgressView("正在读取你的工作空间…").frame(maxWidth: .infinity).padding(40) }
                    else if store.connections.isEmpty { onboarding }
                    else {
                        connectionSection
                        if store.workspace != nil { currentWorkspace }
                    }
                }.padding(20).frame(maxWidth: 920).frame(maxWidth: .infinity)
            }.background(Color.listBackground)
                .refreshable { await store.refresh(schedule: true) }
                .navigationTitle("工作台")
                .toolbar {
                    ToolbarItem { Button { showConnect = true } label: { Label("添加连接", systemImage: "plus") }.disabled(store.demo) }
                    ToolbarItem { Button { showSettings = true } label: { Label("设置", systemImage: "gearshape") } }
                }
                .sheet(isPresented: $showConnect) { AddConnectionView() }
                .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }
    private var onboarding: some View {
        WorkspaceCard {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 40)).foregroundStyle(Color.brandPrimary)
                Text("从连接第一个 Agent 开始").font(.title3.weight(.semibold))
                step("1", "保存连接", "填写名称和 Agent 的完整 URN。")
                step("2", "在本机授权", "用你的控制台身份完成一次配对。")
                step("3", "接续工作", "对话、联系人和协作进展会自动同步。")
                Button { showConnect = true } label: { Label("连接 Agent", systemImage: "plus").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
    }
    private func step(_ index: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(index).font(.subheadline.bold()).frame(width: 28, height: 28).background(Color.brandPrimary.opacity(0.1), in: Circle()).foregroundStyle(Color.brandPrimary)
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.subheadline.bold()); Text(detail).font(.subheadline).foregroundStyle(.secondary) }
        }
    }
    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("我的 Agent").font(.headline); Spacer(); Text("\(store.connections.count) 个连接").font(.caption).foregroundStyle(.secondary) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), alignment: .leading)], spacing: 12) {
                ForEach(store.connections) { agent in
                    Button { Task { await store.selectAgent(agent.id) } } label: {
                        WorkspaceCard {
                            HStack(spacing: 12) {
                                AgentAvatar(name: agent.name)
                                VStack(alignment: .leading, spacing: 7) { Text(agent.name).font(.headline).foregroundStyle(.primary); SyncStatusView(sync: agent.sync) }
                                Spacer(minLength: 4)
                                if agent.id == store.selectedAgentID { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.brandPrimary) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.overlay(RoundedRectangle(cornerRadius: 20).stroke(agent.id == store.selectedAgentID ? Color.brandPrimary.opacity(0.45) : .clear, lineWidth: 1.5))
                    }.buttonStyle(.plain).disabled(store.busy != nil)
                }
            }
        }
    }
    @ViewBuilder private var currentWorkspace: some View {
        if let workspace = store.workspace {
            PairingView()
            if !workspace.snapshots.isEmpty {
                WorkspaceCard {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack { Text("现在的进展").font(.headline); Spacer(); if let last = workspace.sync.lastSuccessAt { Text(Date(timeIntervalSince1970: last / 1000), style: .relative).font(.caption).foregroundStyle(.secondary) } }
                        HStack(alignment: .top, spacing: 12) {
                            metric("已保存对话", value: workspace.conversations.count, icon: "bubble.left.and.bubble.right")
                            metric("联系人", value: store.contacts.count, icon: "person.2")
                            metric("待确认", value: store.pendingCount, icon: "hand.raised")
                        }
                        Divider()
                        if store.pendingCount > 0 {
                            Label("\(store.pendingCount) 项协作请求等待你在 Agent 原生渠道确认。", systemImage: "hand.raised.fill").font(.subheadline).foregroundStyle(Color.statusWarning)
                        } else { Text("接续上次的想法，或交给 Agent 一件新任务。").font(.subheadline).foregroundStyle(.secondary) }
                        HStack {
                            Button { store.tab = 1 } label: { Label("继续对话", systemImage: "arrow.up.right.message").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
                            Button { store.tab = 2 } label: { Text("查看协作").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                        }.controlSize(.large)
                    }
                }
            }
        }
    }
    private func metric(_ title: String, value: Int, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Image(systemName: icon).foregroundStyle(Color.brandPrimary); Text("\(value)").font(.title.bold()).monospacedDigit(); Text(title).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
