import SwiftUI
import AgentWorkspaceKit

struct MessagesView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var history = false
    @State private var showPairing = false
    @State private var sharingDisclosure: AgentSharingContext?
    @State private var nearBottom = true
    @State private var hasNewResult = false
    @State private var lastReadKey = ""
    @State private var readError: String?
    @State private var focusError: String?
    @State private var focusHandlingKey: String?
    @State private var viewSessionRevision = NetworkManager.shared.sessionRevision
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @FocusState private var composing: Bool
    private var composerPreview: Bool {
        #if DEBUG
        store.demo && ProcessInfo.processInfo.arguments.contains("--demo-composer")
        #else
        false
        #endif
    }
    var body: some View {
        NavigationStack {
            Group {
                if store.connections.isEmpty {
                    EmptyState(title: "先连接一个 Agent", message: "在工作台添加连接并完成本机配对，就能在这里继续对话。", systemImage: "bubble.left.and.bubble.right")
                } else {
                    VStack(spacing: 0) {
                        if !dynamicTypeSize.isAccessibilitySize { AgentPicker().padding(.horizontal, 16).padding(.bottom, 8) }
                        transcript
                        composer
                    }
                }
            }.background(Color.listBackground)
                .navigationTitle("对话")
                .crossPlatformNavigationBarTitleDisplayModeInline()
                .toolbar {
                    ToolbarItem { Button { sharingDisclosure = store.sharingContext } label: { Label("管理共享授权", systemImage: "hand.raised") }.disabled(store.sharingContext == nil) }
                    ToolbarItem { Button { history = true } label: { Label("历史对话", systemImage: "clock.arrow.circlepath") }.disabled(store.workspace == nil) }
                    ToolbarItem { Button { Task { await store.selectConversation(nil) } } label: { Label("新对话", systemImage: "square.and.pencil") }.disabled(store.busy != nil || store.submission != nil || store.workspace == nil || store.demo) }
                    #if os(iOS)
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("完成输入") { composing = false }
                    }
                    #endif
                }
                .sheet(isPresented: $history) { ConversationHistoryView() }
                .sheet(item: $sharingDisclosure) { AgentSharingPermissionView(context: $0) }
                .sheet(isPresented: $showPairing) { NavigationStack { ScrollView { PairingView().padding() }.navigationTitle("连接与权限").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showPairing = false } } } } }
                .task {
                    #if DEBUG
                    if composerPreview && ProcessInfo.processInfo.arguments.contains("--demo-keyboard") { composing = true }
                    #endif
                }
        }
    }
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if dynamicTypeSize.isAccessibilitySize { AgentPicker() }
                    WorkspaceFeedback()
                    if let focusError { InlineNotice(message: focusError, style: .error) }
                    if let readError {
                        InlineNotice(message: readError, style: .error)
                        Button { Task { await markVisibleRead() } } label: { Text("重试已读同步").workspaceTapTarget() }.font(.caption)
                    }
                    if store.hasEarlierTurns {
                        Button { Task { await store.loadEarlier() } } label: { Text(store.busy == "earlier" ? "正在读取…" : "加载更早记录").frame(maxWidth: .infinity).workspaceTapTarget() }
                            .font(.caption).disabled(store.busy != nil)
                    }
                    if store.turns.isEmpty && store.submission == nil {
                        EmptyState(title: store.conversationID.isEmpty ? "有什么想一起推进的？" : "正在接续这个对话", message: store.conversationID.isEmpty ? "把想法、问题，或下一件要做的事告诉你的 Agent。" : "已保存的记录与最新进展会自动同步到这里。", systemImage: "sparkle")
                            .padding(.top, 28)
                        if store.canSend {
                            Button { store.draft = "帮我梳理今天的待办"; composing = true } label: { Text("帮我梳理今天的待办").workspaceTapTarget() }
                                .buttonStyle(.bordered).frame(maxWidth: .infinity)
                        }
                    }
                    ForEach(store.turns.map { ConversationTurn(data: $0) }) { turn in
                        TurnView(turn: turn.data, agentName: store.selectedAgent?.name ?? "Agent").id(turn.id)
                    }
                    if let item = store.submission { submissionCard(item) }
                    Color.clear.frame(height: 1).id("end")
                }.padding(20).frame(maxWidth: 820).frame(maxWidth: .infinity)
            }
            .workspaceScrollDismissesKeyboard()
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - (geometry.contentOffset.y + geometry.containerSize.height) < 100
            } action: { _, value in
                nearBottom = value
                if value { hasNewResult = false }
            }
            .safeAreaInset(edge: .bottom) {
                if hasNewResult {
                    Button { proxy.scrollTo("end", anchor: .bottom); hasNewResult = false } label: {
                        Label("查看最新进展", systemImage: "arrow.down").workspaceTapTarget()
                    }.buttonStyle(.borderedProminent).padding(8)
                        .accessibilityHint("跳转到对话底部")
                }
            }
            .onChange(of: store.turns) { old, new in
                if let id = store.focusTurnID, focusHandlingKey == nil, new.contains(where: { $0.string("turn_id") == id }) {
                    Task { await focusTurn(using: proxy) }
                }
                guard store.busy != "earlier", old != new, store.focusTurnID == nil else { return }
                if nearBottom && !voiceOverEnabled { proxy.scrollTo("end", anchor: .bottom) } else { hasNewResult = true }
            }
            .onChange(of: store.submission) { _, new in
                if new?.phase == "sending" { proxy.scrollTo("end", anchor: .bottom) }
            }
            .refreshable { await store.refresh(schedule: true) }
            .onChange(of: store.conversationID) { _, _ in
                focusError = nil; readError = nil
                if store.focusTurnID == nil { proxy.scrollTo("end", anchor: .bottom) }
            }
            .task(id: store.conversationID + ":" + (store.focusTurnID ?? "")) { await focusTurn(using: proxy) }
            .task(id: visibleReadKey) { await markVisibleRead() }
        }
    }
    private var visibleReadKey: String {
        let latest = store.turns.last(where: { ["completed", "failed", "interrupted"].contains($0.string("status")) && !$0.bool("locally_unconfirmed") })
        return [store.conversationID, latest?.string("turn_id") ?? "", latest?.string("status") ?? "", String(latest?.number("updated_at") ?? 0), String(nearBottom), String(store.tab), store.focusTurnID ?? "", String(describing: scenePhase)].joined(separator: ":")
    }
    private func markVisibleRead() async {
        guard !store.demo, viewSessionRevision == NetworkManager.shared.sessionRevision, scenePhase == .active, store.tab == 1, nearBottom, store.focusTurnID == nil,
              let agentID = store.selectedAgentID, !store.conversationID.isEmpty,
              let terminal = store.turns.last(where: { ["completed", "failed", "interrupted"].contains($0.string("status")) && !$0.bool("locally_unconfirmed") }) else { return }
        let conversationID = store.conversationID
        let savedAt = store.workspace?.conversations.first(where: { $0.id == conversationID })?.updatedAt ?? 0
        let remoteAt = terminal.number("updated_at", default: terminal.number("created_at"))
        let watermark = savedAt > 0 ? savedAt : (remoteAt < 1_000_000_000_000 ? remoteAt * 1000 : remoteAt)
        guard watermark.isFinite, watermark > 0 else { return }
        let key = agentID + ":" + conversationID + ":" + terminal.string("turn_id") + ":" + terminal.string("status") + ":" + String(watermark)
        guard key != lastReadKey else { return }
        lastReadKey = key
        let revision = NetworkManager.shared.sessionRevision
        do {
            _ = try await NetworkManager.shared.updateConversation(agentId: agentID, conversationId: conversationID, patch: ["readAt": .number(watermark)])
            guard revision == NetworkManager.shared.sessionRevision, store.selectedAgentID == agentID, store.conversationID == conversationID else { return }
            readError = nil
        } catch {
            guard revision == NetworkManager.shared.sessionRevision, store.selectedAgentID == agentID, store.conversationID == conversationID else { return }
            if lastReadKey == key { lastReadKey = "" }
            if !(error is CancellationError) { readError = "已读状态尚未同步，内容仍可查看。" + error.localizedDescription }
        }
    }
    private func focusTurn(using proxy: ScrollViewProxy) async {
        guard let id = store.focusTurnID, !id.isEmpty else { return }
        let conversationID = store.conversationID
        let key = conversationID + ":" + id
        guard focusHandlingKey != key else { return }
        focusHandlingKey = key
        defer { if focusHandlingKey == key { focusHandlingKey = nil } }
        focusError = nil
        while !store.turns.contains(where: { $0.string("turn_id") == id }) && store.hasEarlierTurns && store.busy == nil {
            let count = store.turns.count
            await store.loadEarlier()
            guard !Task.isCancelled, store.focusTurnID == id, store.conversationID == conversationID else { return }
            if store.turns.count <= count { break }
        }
        guard !Task.isCancelled, store.focusTurnID == id, store.conversationID == conversationID else { return }
        guard store.turns.contains(where: { $0.string("turn_id") == id }) else {
            focusError = "原回合尚未加载，请读取更早记录或刷新后查看。"
            return
        }
        await Task.yield()
        guard !Task.isCancelled, store.focusTurnID == id, store.conversationID == conversationID else { return }
        nearBottom = false; hasNewResult = false
        if reduceMotion { proxy.scrollTo(id, anchor: .center) }
        else { withAnimation { proxy.scrollTo(id, anchor: .center) } }
        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        if store.focusTurnID == id && store.conversationID == conversationID { store.focusTurnID = nil }
    }
    @ViewBuilder private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.canSend || composerPreview {
                WorkspaceAdaptiveStack(spacing: 12) {
                    TextField("告诉 Agent 你想做什么…", text: $store.draft, axis: .vertical).lineLimit(1...(dynamicTypeSize.isAccessibilitySize ? 2 : 6)).focused($composing).disabled(store.submission != nil)
                        .font(.body)
                        .padding(12).background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.secondary.opacity(0.15)))
                        .accessibilityLabel("消息内容，发送给 \(store.selectedAgent?.name ?? "Agent")")
                    Button { requestSend() } label: {
                        Group {
                            if dynamicTypeSize.isAccessibilitySize { Label("发送", systemImage: "arrow.up") }
                            else { Image(systemName: "arrow.up").font(.title3.bold()) }
                        }.workspaceTapTarget()
                    }.buttonStyle(.borderedProminent).clipShape(RoundedRectangle(cornerRadius: 16)).disabled(!store.canSubmit).accessibilityLabel("发送消息")
                        .accessibilityHint(store.hasAgentSharingPermission ? "发送给当前 Agent" : "先查看并决定是否允许向当前 Agent 共享内容")
                        .keyboardShortcut(.return, modifiers: .command)
                }
                WorkspaceAdaptiveStack(spacing: 8) {
                    if !composing || !dynamicTypeSize.isAccessibilitySize {
                        Text(composerPreview ? "界面演示 · 输入仅供布局检查，发送功能已停用" : "受理后自动同步结果；需要授权的事项会展示具体确认问题。").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if store.draft.count > 7000 || store.draft.utf8.count > 23000 {
                        Text("\(store.draft.count)/8000").font(.caption2).foregroundStyle(store.draft.count > 8000 || store.draft.utf8.count > 24000 ? Color.statusDestructive : .secondary)
                            .accessibilityLabel("消息字数")
                            .accessibilityValue("\(store.draft.count)，最多 8000 字；最多 24000 字节")
                    }
                }
            } else if store.demo {
                Label("界面演示 · 发送功能已停用", systemImage: "eye").font(.caption).foregroundStyle(.secondary)
            } else {
                WorkspaceAdaptiveStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(deniedTitle, systemImage: "lock.shield").font(.subheadline.bold())
                        Text(deniedMessage).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        if store.policyAccess { showPairing = true } else { store.tab = 0 }
                    } label: { Text(store.policyAccess ? "查看设置" : "查看政策").workspaceTapTarget() }.font(.caption)
                }
            }
        }.padding(16).frame(maxWidth: 860).frame(maxWidth: .infinity).background(.bar)
    }
    private func requestSend(retry: Bool = false) {
        composing = false
        guard store.hasAgentSharingPermission else {
            sharingDisclosure = store.sharingContext
            return
        }
        Task { await store.send(retry: retry) }
    }
    private var deniedTitle: String {
        if store.policyAccess && store.capabilities != nil && (!store.contentSafetyAvailable || !store.peerInputSafetyAvailable) { return "需要更新工作区或 Agent" }
        if !store.policyAccess { return store.policy?.bool("paused") == true ? "远程控制已暂停" : "等待政策核验与确认" }
        return store.capabilities == nil || store.workspace?.sync.status == "needs_pairing" ? "完成配对后开始对话" : "发送权限尚未开放"
    }
    private var deniedMessage: String {
        if store.policyAccess && store.capabilities != nil && (!store.contentSafetyAvailable || !store.peerInputSafetyAvailable) { return "当前版本未提供完整的对端内容安全能力，新的发送已暂停。请更新 Web 和 Agent；已保存的私人对话仍可查看。" }
        if !store.policyAccess { return store.policyError ?? "已保存的对话仍可查看。请在工作台核验平台政策，并确认或恢复远程控制。" }
        return "已保存的对话仍可查看。请检查本机配对、有效期限与授权范围。"
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
        if store.available(.conversationGet) { Button { Task { await store.inspectSubmission() } } label: { Text("读取对话核实").workspaceTapTarget() }.buttonStyle(.bordered).disabled(store.busy != nil) }
        if item.retryable { Button { requestSend(retry: true) } label: { Text("重试同一请求").workspaceTapTarget() }.buttonStyle(.bordered).disabled(store.busy != nil || !store.canSend) }
        else { Button { Task { await store.dismissSubmission() } } label: { Text("保留记录并继续").workspaceTapTarget() }.buttonStyle(.bordered).disabled(store.busy != nil) }
    }
}

private struct ConversationTurn: Identifiable {
    let data: RemoteRecord
    var id: String { data.string("turn_id") }
}

struct TurnView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let turn: RemoteRecord
    let agentName: String
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Spacer(minLength: dynamicTypeSize.isAccessibilitySize ? 0 : 30)
                VStack(alignment: .trailing, spacing: 7) {
                    Text(turn.string("text")).textSelection(.enabled).padding(16).background(Color.brandPrimary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
                    WorkspaceAdaptiveStack(spacing: 8) { Text(remoteDate(turn["created_at"])).font(.caption2).foregroundStyle(.secondary); RemoteStatus(status: turn.string("status")) }
                }
            }
            HStack(alignment: .top, spacing: 10) {
                if !dynamicTypeSize.isAccessibilitySize { AgentAvatar(name: agentName, size: 30) }
                VStack(alignment: .leading, spacing: 8) {
                    Text(agentName).font(.caption.bold()).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                    response
                    if turn.string("status") == "completed" { ContentReportButton(kind: "turn", recordID: turn.string("turn_id")) }
                    if !references.isEmpty {
                        ViewThatFits(in: .horizontal) {
                            HStack { relatedButtons }
                            VStack(alignment: .leading, spacing: 8) { relatedButtons }
                        }
                    }
                }
                Spacer(minLength: dynamicTypeSize.isAccessibilitySize ? 0 : 16)
            }
        }.accessibilityElement(children: .contain)
    }
    @ViewBuilder private var response: some View {
        if turn.record("content_review").string("status") == "rejected" {
            InlineNotice(message: "此回复已根据工作区的举报处理决定移除。", style: .info)
        } else {
        switch turn.string("status") {
        case "completed":
            ConversationReplyText(text: turn.string("response").isEmpty ? "Agent 已结束本回合，未返回文本内容。" : turn.string("response")).textSelection(.enabled).lineSpacing(5).padding(16).background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 18))
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
    private var references: [ConversationReference] {
        var result: [ConversationReference] = []
        for item in turn.records("related") {
            let kind = item.string("kind"), id = item.string("id")
            if ["task", "approval", "collaboration", "inbox", "conversation"].contains(kind), isStableID(id) {
                result.append(.init(kind: kind, subjectID: id, turnID: item.string("turn_id")))
            }
            if isStableID(item.string("task_id")) { result.append(.init(kind: "task", subjectID: item.string("task_id"))) }
        }
        if let context = sourceConversation(turn) { result.append(.init(kind: "conversation", subjectID: context.conversationId, turnID: context.turnId ?? "")) }
        var ids = Set<String>()
        return result.filter { ids.insert($0.id).inserted }
    }
    @ViewBuilder private var relatedButtons: some View {
        ForEach(references) { reference in
            Button {
                if reference.kind == "conversation" {
                    Task { await store.navigateToConversation(id: reference.subjectID, turnID: reference.turnID.isEmpty ? nil : reference.turnID) }
                } else { store.collaborationFocusID = reference.subjectID; store.tab = 2 }
            } label: { Label(reference.title, systemImage: reference.kind == "conversation" ? "bubble.left.and.bubble.right" : reference.kind == "inbox" ? "tray" : "arrow.up.right.square").workspaceTapTarget() }
                .font(.caption).buttonStyle(.bordered).disabled(store.busy != nil || store.submission != nil || store.demo)
        }
    }
}

private struct ConversationReference: Identifiable {
    let kind: String
    let subjectID: String
    var turnID = ""
    var id: String { kind + ":" + subjectID + ":" + turnID }
    var title: String {
        switch kind { case "task": return "查看关联事项"; case "approval": return "查看完整确认问题"; case "collaboration": return "查看关联协作"; case "inbox": return "查看关联消息"; default: return "返回来源对话" }
    }
}

private struct ConversationReplyText: View {
    let text: String
    private var content: AttributedString {
        var result = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in result.runs {
            if let link = run.link, !["http", "https"].contains(link.scheme?.lowercased() ?? "") { result[run.range].link = nil }
        }
        return result
    }
    var body: some View {
        Text(content).environment(\.openURL, OpenURLAction { url in ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded })
    }
}

struct ConversationHistoryView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var query = ""
    @State private var remoteID = ""
    @State private var scope = ConversationLibraryScope.active
    @State private var items: [SavedConversationItem] = []
    @State private var before: String?
    @State private var loading = false
    @State private var loadGeneration = 0
    @State private var libraryError: String?
    @State private var editingID: String?
    @State private var renaming: SavedConversationItem?
    @State private var title = ""
    @State private var removing: SavedConversationItem?
    @FocusState private var enteringID: Bool
    private let network = NetworkManager.shared
    private var loadKey: String { (store.selectedAgentID ?? "") + ":" + scope.rawValue + ":" + query + ":" + String(network.sessionRevision) }
    private var changing: Bool { store.busy != nil || store.submission != nil || editingID != nil || store.demo }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Group {
                        if dynamicTypeSize.isAccessibilitySize { scopePicker.pickerStyle(.menu) }
                        else { scopePicker.pickerStyle(.segmented) }
                    }.disabled(editingID != nil)
                } footer: {
                    Text("搜索账号已保存的标题、消息与回复。归档和移除只改变账户历史视图；移除的对话可在「已移除」中恢复。")
                }
                Section(scope.title) {
                    if items.isEmpty && !loading { Text(query.isEmpty ? "这里还没有已保存的对话" : "没有匹配的已保存记录").foregroundStyle(.secondary) }
                    ForEach(items) { item in historyRow(item) }
                    if loading { ProgressView("正在读取已保存历史…") }
                    if before != nil && !loading {
                        Button("加载更多历史") { Task { await load(reset: false) } }.disabled(editingID != nil)
                    }
                }
                Section {
                    TextField("输入完整对话 ID", text: $remoteID).crossPlatformAutocapitalization().autocorrectionDisabled()
                        .focused($enteringID).submitLabel(.done).onSubmit { enteringID = false }.accessibilityLabel("完整对话 ID")
                    Button("读取已有对话") {
                        enteringID = false
                        Task {
                            let id = remoteID.trimmingCharacters(in: .whitespacesAndNewlines)
                            await store.openConversation(id)
                            if store.conversationID == id && store.error == nil { dismiss() }
                        }
                    }.disabled(!isStableID(remoteID.trimmingCharacters(in: .whitespacesAndNewlines)) || !store.available(.conversationGet) || !store.policyAccess || changing)
                } header: { Text("找回其他对话") } footer: { Text("用对话 ID 读取尚未同步到账号的历史记录。") }
                if let libraryError { InlineNotice(message: libraryError, style: .error) }
                if let error = store.error { InlineNotice(message: error, style: .error) }
            }.workspaceScrollDismissesKeyboard()
                .searchable(text: $query, prompt: "搜索标题、消息与回复")
                .navigationTitle("历史对话")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(editingID != nil) } }
                .refreshable { await load(reset: true) }
                .task(id: loadKey) { await load(reset: true, debounce: true) }
                .alert("修改对话名称", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                    TextField("名称", text: $title)
                    if let item = renaming {
                        Button("保存") { Task { await update(item, patch: ["title": .string(title.trimmingCharacters(in: .whitespacesAndNewlines))]) } }
                            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.utf16.count > 120)
                    }
                    Button("取消", role: .cancel) { renaming = nil }
                }
                .confirmationDialog("从账户历史中移除这段对话？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                    if let item = removing { Button("移除账户历史", role: .destructive) { Task { await update(item, patch: ["deleted": true]) } } }
                    Button("取消", role: .cancel) { removing = nil }
                } message: {
                    Text("移除后可在「已移除」中恢复。这不会取消 Agent 的处理、撤销授权或删除 Agent 本机记录；处理未确定时不能移除。")
                }
        }.frame(minWidth: 300, idealWidth: 560, minHeight: 460)
            .interactiveDismissDisabled(editingID != nil)
    }

    private var scopePicker: some View {
        Picker("对话范围", selection: $scope) {
            ForEach(ConversationLibraryScope.allCases) { Text($0.title).tag($0) }
        }
    }

    private func historyRow(_ item: SavedConversationItem) -> some View {
        HStack(spacing: 12) {
            Button { Task { await open(item) } } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(item.title).foregroundStyle(.primary).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                            if item.data.bool("unread") { Circle().fill(Color.brandPrimary).frame(width: 7, height: 7).accessibilityHidden(true) }
                        }
                        if !item.data.record("match").string("excerpt").isEmpty {
                            Text(item.data.record("match").string("excerpt")).font(.caption).foregroundStyle(.secondary).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                        }
                        Text(Date(timeIntervalSince1970: item.data.number("updatedAt") / 1000), format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if item.data.bool("pending") { Image(systemName: "clock").foregroundStyle(Color.statusWarning).accessibilityHidden(true) }
                    if store.conversationID == item.id { Image(systemName: "checkmark").foregroundStyle(Color.brandPrimary).accessibilityHidden(true) }
                }.workspaceTapTarget().contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(changing || item.data.bool("deleted"))
                .accessibilityValue([item.data.bool("unread") ? "未读" : nil, item.data.bool("pending") ? "处理中" : nil, store.conversationID == item.id ? "当前对话" : nil].compactMap { $0 }.joined(separator: "，"))
            Menu {
                if item.data.bool("deleted") {
                    Button("恢复到历史") { Task { await update(item, patch: ["deleted": false]) } }
                } else {
                    Button("修改名称") { title = item.title; renaming = item }
                    Button(item.data.bool("archived") ? "取消归档" : "归档对话") { Task { await update(item, patch: ["archived": .bool(!item.data.bool("archived"))]) } }
                    if item.data.bool("unread") { Button("标为已读") { Task { await update(item, patch: ["readAt": .number(item.data.number("updatedAt"))]) } } }
                    Button("移除账户历史", role: .destructive) { removing = item }
                        .disabled(item.data.bool("pending") || !store.uncertainActions.isEmpty)
                }
            } label: { Image(systemName: "ellipsis.circle").font(.title3).workspaceTapTarget() }
                .accessibilityLabel("管理「\(item.title)」")
                .disabled(changing)
        }.padding(.vertical, 6)
    }

    private func open(_ item: SavedConversationItem) async {
        guard !changing, !item.data.bool("deleted"), item.agentID == store.selectedAgentID, item.sessionRevision == network.sessionRevision else { return }
        // These are already-saved IDs, including archived history. No remote call is needed to select them.
        await store.selectConversation(item.id)
        if store.conversationID == item.id && store.error == nil {
            let turnID = item.data.record("match").string("turnId")
            store.focusTurnID = isStableID(turnID) ? turnID : nil
            store.tab = 1
            dismiss()
        }
    }

    private func load(reset: Bool, debounce: Bool = false) async {
        guard reset || !loading, let agentID = store.selectedAgentID else { return }
        loadGeneration += 1
        let version = loadGeneration, revision = network.sessionRevision, selectedScope = scope, search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        loading = true; libraryError = nil
        if reset { items = []; before = nil }
        defer { if version == loadGeneration { loading = false } }
        do {
            if debounce { try await Task.sleep(for: .milliseconds(250)) }
            try Task.checkCancellation()
            guard search.utf16.count <= 200 else { throw WorkspaceClientError.custom("搜索内容最多支持 200 个字符。") }
            if store.demo {
                let saved = store.workspace?.conversations ?? []
                items = saved.compactMap { conversation in
                    guard selectedScope == .active, let encoded = try? JSONEncoder().encode(conversation), let data = try? JSONDecoder().decode(RemoteRecord.self, from: encoded), search.isEmpty || conversation.title.localizedCaseInsensitiveContains(search) || store.turns.contains(where: { ($0.string("text") + $0.string("response")).localizedCaseInsensitiveContains(search) }) else { return nil }
                    return SavedConversationItem(data: data, agentID: agentID, sessionRevision: revision)
                }
                return
            }
            let page = try await network.fetchConversations(agentId: agentID, query: search, archived: selectedScope == .archived ? "archived" : selectedScope == .deleted ? "all" : "active", deleted: selectedScope == .deleted ? "deleted" : "active", before: reset ? nil : before)
            guard !Task.isCancelled, version == loadGeneration, revision == network.sessionRevision, store.selectedAgentID == agentID, scope == selectedScope else { return }
            let incoming = page.records("items").filter { isStableID($0.string("id")) }.map { SavedConversationItem(data: $0, agentID: agentID, sessionRevision: revision) }
            if reset { items = incoming } else {
                let existing = Set(items.map(\.id))
                items += incoming.filter { !existing.contains($0.id) }
            }
            before = page.bool("hasMore") ? page["before"]?.stringValue : nil
        } catch {
            guard !Task.isCancelled, version == loadGeneration, revision == network.sessionRevision, store.selectedAgentID == agentID else { return }
            libraryError = error.localizedDescription
        }
    }

    private func update(_ item: SavedConversationItem, patch: RemoteRecord) async {
        guard !changing, let agentID = store.selectedAgentID, item.agentID == agentID, item.sessionRevision == network.sessionRevision else { return }
        editingID = item.id; libraryError = nil
        let revision = network.sessionRevision
        defer { editingID = nil }
        do {
            _ = try await network.updateConversation(agentId: agentID, conversationId: item.id, patch: patch)
            guard revision == network.sessionRevision, store.selectedAgentID == agentID else { return }
            if patch.bool("deleted") && store.conversationID == item.id { await store.selectConversation(nil) }
            await store.refresh()
            await load(reset: true)
        } catch {
            guard revision == network.sessionRevision, store.selectedAgentID == agentID else { return }
            libraryError = error.localizedDescription
        }
    }
}

private enum ConversationLibraryScope: String, CaseIterable, Identifiable {
    case active, archived, deleted
    var id: String { rawValue }
    var title: String { switch self { case .active: return "未归档"; case .archived: return "已归档"; case .deleted: return "已移除" } }
}

private struct SavedConversationItem: Identifiable {
    let data: RemoteRecord
    let agentID: String
    let sessionRevision: Int
    var id: String { data.string("id") }
    var title: String { data.string("title").isEmpty ? "未命名对话" : data.string("title") }
}
