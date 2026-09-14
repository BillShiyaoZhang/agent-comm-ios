import SwiftUI

struct ContentView: View {
    @ObservedObject private var network = NetworkManager.shared
    @State private var checked = false
    @State private var sessionError: String?
    private var demo: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--demo-workspace")
        #else
        false
        #endif
    }
    var body: some View {
        Group {
            if demo { MainTabView(demo: true) }
            else if !checked {
                VStack(spacing: 20) {
                    Image(systemName: "bubble.left.and.bubble.right.fill").font(.largeTitle).foregroundStyle(Color.brandPrimary)
                    ProgressView("正在恢复工作台…")
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.listBackground)
            } else if network.isAuthenticated {
                MainTabView().id(network.baseUrl + (network.currentUser?.id ?? "") + String(network.sessionRevision))
            } else {
                LoginView()
                    .safeAreaInset(edge: .top) {
                        if let sessionError { InlineNotice(message: sessionError, style: .error).padding(.horizontal) }
                    }
            }
        }
        .tint(.brandPrimary)
        .task {
            guard !demo else { return }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--preview-login") { checked = true; return }
            #endif
            do { try await network.checkSession() }
            catch { sessionError = "未能恢复登录，请检查连接后重新登录。" }
            checked = true
        }
    }
}

struct MainTabView: View {
    @StateObject private var store: WorkspaceStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    init(demo: Bool = false) { _store = StateObject(wrappedValue: WorkspaceStore(demo: demo)) }
    private var useSidebar: Bool {
        #if os(macOS)
        true
        #else
        sizeClass == .regular
        #endif
    }
    var body: some View {
        Group {
            if useSidebar {
                NavigationSplitView {
                    List {
                        Section("工作空间") {
                            sidebarButton("工作台", icon: "square.grid.2x2", tag: 0)
                            sidebarButton("对话", icon: "bubble.left.and.bubble.right", tag: 1)
                            sidebarButton("协作", icon: "person.2", tag: 2)
                        }
                        Section("我的 Agent") {
                            ForEach(store.connections) { agent in
                                Button { Task { await store.selectAgent(agent.id) } } label: {
                                    HStack { AgentAvatar(name: agent.name, size: 30); Text(agent.name).foregroundStyle(.primary); Spacer(); if agent.id == store.selectedAgentID { Image(systemName: "checkmark").foregroundStyle(Color.brandPrimary) } }
                                }.disabled(store.busy != nil)
                            }
                        }
                    }
                    .navigationTitle("Agent Workspace")
                    .toolbar { ToolbarItem { Button { showSettings = true } label: { Label("设置", systemImage: "gearshape") } } }
                } detail: { selectedPage }
            } else {
                TabView(selection: $store.tab) {
                    DashboardView().tabItem { Label("工作台", systemImage: "square.grid.2x2") }.tag(0)
                    MessagesView().tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right") }.tag(1)
                    CollaborationView().tabItem { Label("协作", systemImage: "person.2") }.badge(store.pendingCount).tag(2)
                }
            }
        }
        .environmentObject(store)
        .onAppear {
            #if DEBUG
            if store.demo {
                let arguments = ProcessInfo.processInfo.arguments
                if arguments.contains("--demo-messages") { store.tab = 1 }
                if arguments.contains("--demo-collaboration") { store.tab = 2 }
            }
            #endif
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .task(id: scenePhase) { if scenePhase == .active { await store.run() } else { store.saveDraft() } }
        .onChange(of: store.draft) { _, _ in store.saveDraft() }
    }
    @ViewBuilder private var selectedPage: some View {
        switch store.tab { case 1: MessagesView(); case 2: CollaborationView(); default: DashboardView() }
    }
    private func sidebarButton(_ title: String, icon: String, tag: Int) -> some View {
        Button { store.tab = tag } label: {
            HStack { Label(title, systemImage: icon); Spacer(); if tag == 2 && store.pendingCount > 0 { Text("\(store.pendingCount)").font(.caption.bold()) } }
                .foregroundStyle(store.tab == tag ? Color.brandPrimary : .primary)
                .padding(.vertical, 6)
        }.listRowBackground(store.tab == tag ? Color.brandPrimary.opacity(0.10) : .clear)
    }
}
