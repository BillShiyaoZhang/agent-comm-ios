import SwiftUI
import AgentWorkspaceKit

struct MessagesView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var history = false
    @State private var showPairing = false
    @State private var nearBottom = true
    @State private var hasNewResult = false
    @FocusState private var composing: Bool
    var body: some View {
        NavigationStack {
            Group {
                if store.connections.isEmpty {
                    EmptyState(title: "先连接一个 Agent", message: "在工作台添加连接并完成本机配对，就能在这里继续对话。", systemImage: "bubble.left.and.bubble.right")
                } else {
                    VStack(spacing: 0) {
                        AgentPicker().padding(.horizontal, 16).padding(.bottom, 8)
                        transcript
                        composer
                    }
                }
            }.background(Color.listBackground)
                .navigationTitle("对话")
                .crossPlatformNavigationBarTitleDisplayModeInline()
                .toolbar {
                    ToolbarItem { Button { history = true } label: { Label("历史对话", systemImage: "clock.arrow.circlepath") }.disabled(store.workspace == nil) }
                    ToolbarItem { Button { Task { await store.selectConversation(nil) } } label: { Label("新对话", systemImage: "square.and.pencil") }.disabled(store.busy != nil || store.submission != nil || store.workspace == nil || store.demo) }
                }
                .sheet(isPresented: $history) { ConversationHistoryView() }
                .sheet(isPresented: $showPairing) { NavigationStack { ScrollView { PairingView().padding() }.navigationTitle("连接与权限").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showPairing = false } } } } }
        }
    }
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    WorkspaceFeedback()
                    if store.hasEarlierTurns { Button(store.busy == "earlier" ? "正在读取…" : "加载更早记录") { Task { await store.loadEarlier() } }.font(.caption).frame(maxWidth: .infinity).disabled(store.busy != nil) }
                    if store.turns.isEmpty && store.submission == nil {
                        EmptyState(title: store.conversationID.isEmpty ? "有什么想一起推进的？" : "正在接续这个对话", message: store.conversationID.isEmpty ? "把想法、问题，或下一件要做的事告诉你的 Agent。" : "已保存的记录与最新进展会自动同步到这里。", systemImage: "sparkle")
                            .padding(.top, 28)
                        if store.canSend {
                            Button("帮我梳理今天的待办") { store.draft = "帮我梳理今天的待办"; composing = true }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                        }
                    }
                    ForEach(store.turns.map { ConversationTurn(data: $0) }) { turn in TurnView(turn: turn.data, agentName: store.selectedAgent?.name ?? "Agent") }
                    if let item = store.submission { submissionCard(item) }
                    Color.clear.frame(height: 1).id("end")
                }.padding(20).frame(maxWidth: 820).frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - (geometry.contentOffset.y + geometry.containerSize.height) < 100
            } action: { _, value in
                nearBottom = value
                if value { hasNewResult = false }
            }
            .overlay(alignment: .bottom) {
                if hasNewResult {
                    Button("查看最新进展 ↓") { proxy.scrollTo("end", anchor: .bottom); hasNewResult = false }.buttonStyle(.borderedProminent).padding(8)
                }
            }
            .onChange(of: store.turns) { old, new in
                guard store.busy != "earlier", old != new else { return }
                if nearBottom { proxy.scrollTo("end", anchor: .bottom) } else { hasNewResult = true }
            }
            .onChange(of: store.submission) { _, new in
                if new?.phase == "sending" { proxy.scrollTo("end", anchor: .bottom) }
            }
            .refreshable { await store.refresh(schedule: true) }
            .onChange(of: store.conversationID) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }
    @ViewBuilder private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.canSend {
                HStack(alignment: .bottom, spacing: 12) {
                    TextField("告诉 Agent 你想做什么…", text: $store.draft, axis: .vertical).lineLimit(2...6).focused($composing).disabled(store.submission != nil)
                        .padding(12).background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.secondary.opacity(0.15)))
                        .accessibilityLabel("消息内容")
                    Button { composing = false; Task { await store.send() } } label: {
                        Image(systemName: "arrow.up").font(.title3.bold()).frame(width: 46, height: 46)
                    }.buttonStyle(.borderedProminent).clipShape(RoundedRectangle(cornerRadius: 16)).disabled(!store.canSubmit).accessibilityLabel("发送消息")
                        .keyboardShortcut(.return, modifiers: .command)
                }
                HStack {
                    Text("受理后自动同步结果；协作确认请回到 Agent 原生渠道。").font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if store.draft.count > 7000 || store.draft.utf8.count > 23000 { Text("\(store.draft.count)/8000").font(.caption2).foregroundStyle(store.draft.count > 8000 || store.draft.utf8.count > 24000 ? Color.statusDestructive : .secondary) }
                }
            } else if store.demo {
                Label("界面演示 · 发送功能已停用", systemImage: "eye").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lock.shield").foregroundStyle(Color.brandPrimary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.capabilities == nil ? "完成配对后开始对话" : "发送权限尚未开放").font(.subheadline.bold())
                        Text("已保存的对话仍可查看。请检查本机配对与授权范围。").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("查看设置") { showPairing = true }.font(.caption)
                }
            }
        }.padding(16).frame(maxWidth: 860).frame(maxWidth: .infinity).background(.bar)
    }
    private func submissionCard(_ item: WorkspaceSubmission) -> some View {
        WorkspaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(item.text).textSelection(.enabled)
                Label(item.phase == "sending" ? "正在等待受理回执" : "发送结果待核实", systemImage: item.phase == "sending" ? "clock" : "exclamationmark.circle").font(.subheadline.bold()).foregroundStyle(Color.statusWarning)
                if item.phase != "sending" {
                    Text("这条消息可能已经被处理。请先核实，重试将使用同一个请求编号。").font(.caption).foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack { recoveryActions(item) }
                        VStack(alignment: .leading) { recoveryActions(item) }
                    }
                }
            }
        }
    }
    @ViewBuilder private func recoveryActions(_ item: WorkspaceSubmission) -> some View {
        if store.available(.conversationGet) { Button("读取对话核实") { Task { await store.inspectSubmission() } }.buttonStyle(.bordered).disabled(store.busy != nil) }
        if item.retryable { Button("重试同一请求") { Task { await store.send(retry: true) } }.buttonStyle(.bordered).disabled(store.busy != nil || !store.canSend) }
        else { Button("保留记录并继续") { Task { await store.dismissSubmission() } }.buttonStyle(.bordered).disabled(store.busy != nil) }
    }
}

private struct ConversationTurn: Identifiable {
    let data: RemoteRecord
    var id: String { data.string("turn_id") }
}

struct TurnView: View {
    let turn: RemoteRecord
    let agentName: String
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Spacer(minLength: 30)
                VStack(alignment: .trailing, spacing: 7) {
                    Text(turn.string("text")).textSelection(.enabled).padding(16).background(Color.brandPrimary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
                    HStack(spacing: 8) { Text(remoteDate(turn["created_at"])).font(.caption2).foregroundStyle(.secondary); RemoteStatus(status: turn.string("status")) }
                }
            }
            HStack(alignment: .top, spacing: 10) {
                AgentAvatar(name: agentName, size: 30)
                VStack(alignment: .leading, spacing: 8) {
                    Text(agentName).font(.caption.bold()).foregroundStyle(.secondary)
                    response
                }
                Spacer(minLength: 16)
            }
        }.accessibilityElement(children: .contain)
    }
    @ViewBuilder private var response: some View {
        switch turn.string("status") {
        case "completed":
            Text(turn.string("response").isEmpty ? "Agent 已结束本回合，未返回文本内容。" : turn.string("response")).textSelection(.enabled).lineSpacing(5).padding(16).background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 18))
        case "failed", "interrupted":
            VStack(alignment: .leading, spacing: 8) {
                Text(turn.string("status") == "failed" ? "这个回合未能完成。" : "处理结果尚未确认，请先核实。")
                if !turn.string("error").isEmpty { Text(turn.string("error")).font(.caption) }
            }.foregroundStyle(Color.statusDestructive).padding(16).background(Color.statusDestructive.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
        default:
            Label(turn.string("status") == "running" ? "正在处理这一回合…" : "已受理，等待开始处理…", systemImage: "clock").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 10)
        }
    }
}

struct ConversationHistoryView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var remoteID = ""
    var body: some View {
        NavigationStack {
            List {
                Section("已保存到账号") {
                    if store.workspace?.conversations.isEmpty != false { Text("还没有已保存的对话").foregroundStyle(.secondary) }
                    ForEach((store.workspace?.conversations ?? []).filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { item in
                        Button {
                            Task { await store.selectConversation(item.id); if store.conversationID == item.id { dismiss() } }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.title.isEmpty ? "未命名对话" : item.title).foregroundStyle(.primary).lineLimit(2)
                                    Text(Date(timeIntervalSince1970: item.updatedAt / 1000), format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if item.pending { Image(systemName: "clock").foregroundStyle(Color.statusWarning) }
                                if store.conversationID == item.id { Image(systemName: "checkmark").foregroundStyle(Color.brandPrimary) }
                            }.padding(.vertical, 6)
                        }.disabled(store.busy != nil || store.submission != nil || store.demo)
                    }
                }
                Section {
                    TextField("输入完整对话 ID", text: $remoteID).crossPlatformAutocapitalization().autocorrectionDisabled()
                    Button("读取已有对话") { Task { await store.openConversation(remoteID.trimmingCharacters(in: .whitespacesAndNewlines)); if store.error == nil { dismiss() } } }.disabled(remoteID.isEmpty || !store.available(.conversationGet) || store.busy != nil || store.submission != nil || store.demo)
                } header: { Text("找回其他对话") } footer: { Text("用对话 ID 读取尚未同步到账号的历史记录。") }
                if let error = store.error { InlineNotice(message: error, style: .error) }
            }.searchable(text: $query, prompt: "搜索对话")
                .navigationTitle("历史对话")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.frame(minWidth: 300, idealWidth: 560, minHeight: 460)
    }
}
