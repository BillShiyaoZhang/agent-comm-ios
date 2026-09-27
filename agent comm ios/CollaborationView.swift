import SwiftUI
import AgentWorkspaceKit

enum CollaborationSection: String, CaseIterable { case tasks = "事项", contacts = "联系人", inbox = "收件箱" }

struct CollaborationView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var section = CollaborationSection.tasks
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if store.connections.isEmpty {
                        EmptyState(title: "协作从连接开始", message: "添加 Agent 后，联系人、协作事项和收件箱会汇集在这里。", systemImage: "person.2")
                    } else {
                        AgentPicker()
                        sectionPicker
                        WorkspaceFeedback()
                        SocialActionFeedback()
                        if let last = snapshot?.time {
                            Label("最近同步 " + Date(timeIntervalSince1970: last / 1000).formatted(date: .abbreviated, time: .shortened), systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if snapshot == nil {
                            EmptyState(title: "等待首次同步", message: "完成本机配对后，Agent 开放的数据会显示在这里。", systemImage: "arrow.triangle.2.circlepath")
                            Button { store.tab = 0 } label: { Text("查看连接设置").workspaceTapTarget() }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                        } else {
                            Group {
                                switch section {
                                case .tasks:
                                    if store.contentSafetyAvailable || store.demo { tasks }
                                    else { InlineNotice(message: "当前工作区尚未提供对端内容审核。请更新 Web 服务；联系人安全设置仍可使用。", style: .info) }
                                case .contacts: contacts
                                case .inbox: inbox
                                }
                            }.id(store.selectedAgentID)
                            if let data = snapshot?.data { SnapshotDetails(data: data) }
                        }
                    }
                }.padding(20).frame(maxWidth: 920).frame(maxWidth: .infinity)
            }.background(Color.listBackground)
                .task(id: store.collaborationFocusID) {
                    guard let id = store.collaborationFocusID else { return }
                    if store.inbox.contains(where: { $0.string("message_id") == id }) { section = .inbox }
                    else if store.contacts.contains(where: { $0.string("contact_id") == id }) || store.contactRequests.contains(where: { $0.string("request_id") == id }) { section = .contacts }
                    else { section = .tasks }
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled else { return }
                    if reduceMotion { proxy.scrollTo(focusTarget(for: id), anchor: .top) }
                    else { withAnimation { proxy.scrollTo(focusTarget(for: id), anchor: .top) } }
                }
                .refreshable { await store.refresh(schedule: true) }
                .onAppear {
                    #if DEBUG
                    if store.demo {
                        if ProcessInfo.processInfo.arguments.contains("--demo-contacts") { section = .contacts }
                        if ProcessInfo.processInfo.arguments.contains("--demo-inbox") { section = .inbox }
                    }
                    #endif
                }
                .navigationTitle("协作")
                .toolbar {
                    ToolbarItem {
                        Button { Task { await store.invoke(method) } } label: { Label("读取最新内容", systemImage: "arrow.clockwise").workspaceTapTarget() }
                            .disabled(!store.available(method) || store.busy != nil || store.demo)
                    }
                }
            }
        }
    }

    @ViewBuilder private var sectionPicker: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Picker("查看内容", selection: $section) {
                ForEach(CollaborationSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.menu).workspaceTapTarget()
        } else {
            #if os(iOS)
            segmentedSectionPicker.accessibilityShowsLargeContentViewer()
            #else
            segmentedSectionPicker
            #endif
        }
    }
    private var segmentedSectionPicker: some View {
        Picker("查看内容", selection: $section) {
            ForEach(CollaborationSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).workspaceTapTarget()
    }

    private var method: RPCMethod {
        switch section { case .tasks: return .collaborationState; case .contacts: return .contactsList; case .inbox: return .inboxList }
    }
    private var snapshot: WorkspaceSnapshot? {
        store.workspace?.snapshots[method.rawValue] ?? ((section != .tasks) ? store.workspace?.snapshots["collaboration.state"] : nil)
    }
    private var collaborationView: RemoteRecord {
        let data = store.collaboration
        if data["collaborations"]?.arrayValue != nil { return data }
        return data["collaboration"]?.objectValue ?? data.record("collaboration_v2")
    }
    private var allOperations: [RemoteRecord] {
        var seen = Set<String>()
        return (store.collaboration.records("operations") + collaborationView.records("operations")).filter { operation in
            let id = operation.string("operation_id")
            return id.isEmpty || seen.insert(id).inserted
        }
    }
    private func focusTarget(for id: String) -> String {
        if let collaboration = collaborationView.records("collaborations").first(where: { $0.string("collaboration_id") == id }), store.collaboration.records("tasks").contains(where: { $0.string("task_id") == collaboration.string("task_id") }) { return collaboration.string("task_id") }
        if let operation = allOperations.first(where: { $0.string("operation_id") == id }), store.collaboration.records("tasks").contains(where: { $0.string("task_id") == operation.string("task_id") }) { return operation.string("task_id") }
        return id
    }

    private var tasks: some View {
        VStack(alignment: .leading, spacing: 16) {
            let data = store.collaboration
            let approvals = data["pending_confirmations"]?.arrayValue?.compactMap(\.objectValue) ?? data.records("approvals")
            if !approvals.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Label("\(approvals.count) 项需要你确认", systemImage: "hand.raised.fill").font(.headline).foregroundStyle(Color.statusWarning)
                    Text("核对完整问题后明确选择。阅读、聊天回复和已读状态不会授予权限。").font(.subheadline).foregroundStyle(.secondary)
                    ForEach(socialRecordRows(approvals, key: "approval_id")) { item in ApprovalRequestCard(approval: item.data).id(item.data.string("approval_id")) }
                }.padding(18).background(Color.statusWarning.opacity(0.09), in: RoundedRectangle(cornerRadius: 20))
            }
            let invitations = collaborationView.records("invitations").filter { !store.isRecordHidden(kind: "collaboration", id: $0.string("message_id")) && !store.isRecordHidden(kind: "collaboration", id: $0.string("collaboration_id")) }
            ForEach(socialRecordRows(invitations, key: "message_id", fallbackKeys: ["collaboration_id"])) { item in
                let invitation = item.data
                WorkspaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("收到协作邀请 · 对端声明", systemImage: "envelope.open").font(.caption).foregroundStyle(.secondary)
                        Text(invitation.string("topic", default: "协作邀请")).font(.headline)
                        Text(invitation.string("sender_urn")).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        if !socialDate(invitation["expires_at"]).isEmpty { Text("邀请截止：" + socialDate(invitation["expires_at"])).font(.caption).foregroundStyle(.secondary) }
                        Text("请在下方功能中核对邀请、自己的范围与资料披露，再准备加入。好友关系和对方邀请不会授予本方协作权限。").font(.caption).foregroundStyle(.secondary)
                        SnapshotDetails(data: invitation)
                    }
                }
            }
            let records = data.records("tasks").filter { !store.isRecordHidden(kind: "collaboration", id: $0.string("task_id")) }
            let collaborations = collaborationView.records("collaborations").filter { !store.isRecordHidden(kind: "collaboration", id: $0.string("collaboration_id")) && !store.isRecordHidden(kind: "collaboration", id: $0.string("task_id")) }
            if records.isEmpty && approvals.isEmpty && allOperations.isEmpty && collaborations.isEmpty && invitations.isEmpty {
                EmptyState(title: "暂时没有协作事项", message: "交给 Agent 的协作事项和待确认请求，会在这里汇集。", systemImage: "checklist")
            }
            ForEach(socialRecordRows(records, key: "task_id")) { item in
                let task = item.data
                CollaborationTaskCard(task: task, collaboration: collaborations.first { $0.string("task_id") == task.string("task_id") }, operations: allOperations.filter { $0.string("task_id") == task.string("task_id") }, data: data)
                    .id(task.string("task_id"))
            }
            ForEach(socialRecordRows(collaborations.filter { collaboration in !records.contains { $0.string("task_id") == collaboration.string("task_id") } }, key: "collaboration_id", fallbackKeys: ["task_id"])) { item in
                let collaboration = item.data
                CollaborationTaskCard(task: ["task_id": collaboration["task_id"] ?? .string(collaboration.string("collaboration_id"))], collaboration: collaboration, operations: allOperations.filter { $0.string("collaboration_id") == collaboration.string("collaboration_id") }, data: data)
                    .id(collaboration.string("collaboration_id"))
            }
            let orphaned = allOperations.filter { operation in
                !store.isRecordHidden(kind: "collaboration", id: operation.string("task_id")) && !store.isRecordHidden(kind: "collaboration", id: operation.string("collaboration_id")) && !records.contains { $0.string("task_id") == operation.string("task_id") } && !collaborations.contains { $0.string("collaboration_id") == operation.string("collaboration_id") }
            }
            ForEach(socialRecordRows(orphaned, key: "operation_id")) { item in WorkspaceCard { OperationView(operation: item.data) }.id(item.data.string("operation_id")) }
            MeetingGoalForm()
            CollaborationActionForm()
            DeletedSocialRecordsView(kind: "collaboration")
        }
    }

    private var contacts: some View {
        VStack(alignment: .leading, spacing: 14) {
            AddContactForm()
            ContactRequestsView()
            if !store.contacts.isEmpty {
                HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true); TextField("搜索姓名、别名或 URN", text: $query).autocorrectionDisabled().accessibilityLabel("搜索联系人") }
                    .padding(14).background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 14))
            }
            let visible = store.contacts.filter { query.isEmpty || ($0.string("contact_id") + " " + $0.string("alias") + " " + $0.string("urn") + " " + $0.strings("aliases").joined(separator: " ")).localizedCaseInsensitiveContains(query) }
            if visible.isEmpty {
                EmptyState(title: query.isEmpty ? "联系人会出现在这里" : "没有匹配的联系人", message: query.isEmpty ? "添加联系人并等待对方接受，双方即可互发普通消息。" : "试试其他姓名、别名或 URN。", systemImage: "person.crop.circle.badge.plus")
            }
            LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 280))], spacing: 12) {
                ForEach(socialRecordRows(visible, key: "contact_id", fallbackKeys: ["urn"])) { item in ContactCard(contact: item.data, syncedAt: snapshot?.time ?? 0).id(item.data.string("contact_id")) }
            }
            DeletedSocialRecordsView(kind: "contact")
            BlockedPeersView()
        }
    }

    private var inbox: some View {
        VStack(alignment: .leading, spacing: 14) {
            PeerMessageForm()
            if store.inbox.isEmpty && store.pendingContentReviews.isEmpty { EmptyState(title: "收件箱很安静", message: "来自其他 Agent 的消息，会在这里显示。", systemImage: "tray") }
            else { Text("消息来自对端 Agent，内容仍需核实；涉及授权，请在「事项」中核对完整问题。").font(.caption).foregroundStyle(.secondary) }
            ForEach(socialRecordRows(Array(store.inbox.reversed()), key: "message_id")) { item in InboxMessageCard(message: item.data).id(item.data.string("message_id")) }
            ForEach(socialRecordRows(store.pendingContentReviews, key: "message_id")) { item in
                WorkspaceCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(item.data.string("sender_urn")).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        PendingContentReview(messageID: item.data.string("message_id"))
                        PeerSafetyControls(urn: item.data.string("sender_urn"))
                        ContentReportButton(kind: "inbox", recordID: item.data.string("message_id"))
                    }
                }
            }
            SentMessagesView()
        }
    }
}

struct CollaborationTaskCard: View {
    @EnvironmentObject private var store: WorkspaceStore
    let task: RemoteRecord
    let collaboration: RemoteRecord?
    let operations: [RemoteRecord]
    let data: RemoteRecord
    @State private var detailsOpen = false

    var body: some View {
        WorkspaceCard {
            VStack(alignment: .leading, spacing: 14) {
                let scope = task.record("scope")
                let terms = collaboration?.record("terms") ?? [:]
                WorkspaceAdaptiveStack {
                    Text(scope.string("topic", default: terms.string("topic", default: scope.string("purpose", default: "协作事项")))).font(.headline)
                    StatusBadge(text: phaseText, color: collaboration?.string("phase") == "closed" ? .statusSuccess : .statusWarning)
                }
                summary("目标", scope.string("purpose", default: scope.string("topic", default: terms.string("topic", default: "当前记录未提供"))))
                summary("已发生", progress)
                summary("下一步", nextStep)
                summary("结果与完成范围", result)
                if let waiting = collaboration?.string("waiting_reason"), !waiting.isEmpty { Text(socialWaitingLabel(waiting)).font(.caption).foregroundStyle(Color.statusWarning) }
                DisclosureGroup(isExpanded: $detailsOpen) {
                    VStack(alignment: .leading, spacing: 12) {
                        if let peer = collaboration?.string("peer_urn"), !peer.isEmpty { summary("确切接收方", peer) }
                        let participants = scope.strings("participant_ids")
                        if !participants.isEmpty { summary("参与方", participants.joined(separator: "、")) }
                        summary("授权截止", socialDate(scope["expires_at"]).isEmpty ? "当前记录未提供" : socialDate(scope["expires_at"]))
                        let capabilities = scope.strings("capabilities")
                        if !capabilities.isEmpty { summary("允许能力", capabilities.map(socialCapabilityLabel).joined(separator: "、")) }
                        if let maximum = scope["max_actions"]?.numberValue { summary("业务动作预算", socialScalar(task["used_count"]) + " / " + socialScalar(.number(maximum))) }
                        ForEach(Array(scope.records("allowed_windows").enumerated()), id: \.offset) { _, window in Text(socialDate(window["start"]) + " — " + socialDate(window["end"])).font(.caption) }
                        if !terms.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("当前方案" + (terms["version"] != nil ? " · 第 \(socialScalar(terms["version"])) 版" : "")).font(.subheadline.bold())
                                Text(terms.string("topic")).font(.subheadline)
                                Text(socialDate(terms["start"]) + " — " + socialDate(terms["end"])).font(.caption)
                                Text("当前快照未提供完整历史条款，不能据此推断版本差异。").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let agreement = collaboration?.record("agreement"), !agreement.isEmpty {
                            summary("约定编号", agreement.string("agreement_id", default: "当前记录未提供"))
                            Text(collaboration?.bool("agreement_synced") == true ? "已有对端同步回执 · 尚未创建日历" : "仍待对端同步回执 · 尚未创建日历").font(.caption).foregroundStyle(.secondary)
                        }
                        let resources = data.records("resources").filter { scope.strings("resource_ids").contains($0.string("resource_id")) }
                        ForEach(socialRecordRows(resources, key: "resource_id")) { item in
                            let resource = item.data
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(resource.string("text")).font(.subheadline).textSelection(.enabled)
                                    let source = resource.record("provenance")
                                    if !source.isEmpty { SnapshotDetails(data: source) }
                                    Text("允许分享不等于已经披露；实际发送证据见操作记录。").font(.caption).foregroundStyle(.secondary)
                                }.padding(.top, 8)
                            } label: { Text(resource.string("title", default: "允许分享的资料")).frame(maxWidth: .infinity, alignment: .leading).workspaceTapTarget() }
                        }
                        ForEach(socialRecordRows(operations, key: "operation_id")) { item in OperationView(operation: item.data).id(item.data.string("operation_id")) }
                        Text("事项 · " + task.string("task_id")).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        if let collaboration, !collaboration.string("collaboration_id").isEmpty {
                            Text("协作 · " + collaboration.string("collaboration_id")).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            ContentReportButton(kind: "collaboration", recordID: collaboration.string("collaboration_id"))
                        }
                        let source = task.record("source_context").isEmpty ? collaboration?.record("source_context") ?? [:] : task.record("source_context")
                        RelatedConversationLink(source: source)
                        SocialRecordAction(kind: "collaboration", recordID: task.string("task_id", default: collaboration?.string("collaboration_id") ?? ""), title: scope.string("topic", default: terms.string("topic", default: "协作事项")))
                    }.padding(.top, 10)
                } label: { Text("授权范围、方案与来源").frame(maxWidth: .infinity, alignment: .leading).workspaceTapTarget() }.font(.subheadline)
            }
        }.task(id: store.collaborationFocusID) {
            if let id = store.collaborationFocusID, id == collaboration?.string("collaboration_id") || operations.contains(where: { $0.string("operation_id") == id }) { detailsOpen = true }
        }
    }
    @ViewBuilder private func summary(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(label).font(.caption).foregroundStyle(.secondary); Text(text).font(.subheadline).textSelection(.enabled) }
            .accessibilityElement(children: .combine)
    }
    private var phaseText: String {
        guard let collaboration else { return stateText(task.string("status")) }
        if collaboration.string("phase") == "closed" { return ["agreement_only_complete": "本轮协作已结束", "cancelled": "双方已取消约定", "withdrawn": "已撤回接受", "expired": "已到期"][collaboration.string("closure_reason")] ?? "本轮协作已结束" }
        return ["invited": "已发起邀请", "negotiating": "正在协调方案", "partially_accepted": "部分接受", "agreed": "已形成双方约定", "reconciling": "正在核对双方状态"][collaboration.string("phase")] ?? "状态待核对"
    }
    private var completedAgreement: Bool { collaboration?.string("closure_reason") == "agreement_only_complete" && collaboration?.bool("agreement_synced") == true }
    private var uncertain: Bool { operations.contains { ["sending", "uncertain"].contains($0.string("status")) } || collaboration?.bool("withdraw_pending") == true }
    private var progress: String {
        if collaboration?.string("closure_reason") == "cancelled" { return "双方已确认取消约定。" }
        if completedAgreement { return "双方已同步同版约定。" }
        if task.string("status") == "revoked" { return "委托已撤销，停止新的业务动作；既有协作结果保留。" }
        if collaboration?["agreement"]?.objectValue != nil { return "本方已记录约定，仍需核对对端同步结果。" }
        if collaboration?.bool("joined") == true { return "双方已加入，协调当前方案。" }
        if collaboration != nil { return "邀请已进入协作流程，尚未确认双方加入。" }
        return task.string("status") == "active" ? "委托已授权，尚未邀请或加入。" : "委托范围等待本人确认。"
    }
    private var nextStep: String {
        if uncertain { return "先核实原动作，请保留原操作记录。" }
        let ids = Set([task.string("task_id")] + operations.map { $0.string("operation_id") } + operations.map { $0.string("approval_id") })
        if data.records("pending_confirmations").contains(where: { ids.contains($0.string("subject_id")) || ids.contains($0.string("approval_id")) || $0.string("task_id") == task.string("task_id") }) { return "本人在上方核对当前完整问题。" }
        if operations.contains(where: { $0.string("status") == "ready" && $0.string("decision") != "deny" }) { return "核对已授权动作后，通过下方可用功能实际执行。" }
        if completedAgreement || collaboration?.string("closure_reason") == "cancelled" { return "查看结果；需要时继续讨论。" }
        if task.string("status") == "revoked" { return "查看已发生动作；必要时单独处理撤回或取消。" }
        if let reason = collaboration?.string("waiting_reason"), !reason.isEmpty { return socialWaitingLabel(reason) }
        if collaboration?.bool("joined") == true { return task.record("worker").string("status") == "active" ? "有限后台程序按已批准策略推进。" : "本人选择方案或设置有限后台范围。" }
        return collaboration == nil ? "本人准备邀请或核对收到的邀请。" : "等待对方加入，核对同步后的状态。"
    }
    private var result: String {
        if completedAgreement { return "已形成并同步线上会议约定。未创建日历，尚不代表会议已举行。" }
        if collaboration?.string("closure_reason") == "cancelled" { return "已有双方取消结果；已披露的资料仍保留。" }
        return collaboration?["agreement"]?.objectValue != nil ? "约定已在本方记录，等待完整同步证据。" : "尚无双方完成结果。"
    }
}

struct OperationView: View {
    let operation: RemoteRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkspaceAdaptiveStack { Text(socialOperationLabel(operation)).font(.caption.bold()); RemoteStatus(status: operation.string("status")) }
            if !operation.string("text").isEmpty { Text(operation.string("text")).font(.subheadline).textSelection(.enabled) }
            if operation.string("status") == "accepted" { Text("本机队列已接收；尚不代表对方同意或事项完成。").font(.caption).foregroundStyle(.secondary) }
            if operation.string("kind") == "join" && operation.string("status") == "denied" { Text("不加入仅记录本方决定，尚未发送专用拒绝通知。").font(.caption).foregroundStyle(.secondary) }
            if !operation.string("operation_id").isEmpty { Text("原动作 · " + operation.string("operation_id")).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(Color.listBackground, in: RoundedRectangle(cornerRadius: 14))
    }
}
