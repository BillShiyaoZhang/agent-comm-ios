import SwiftUI
import AgentWorkspaceKit

enum CollaborationSection: String, CaseIterable { case tasks = "事项", contacts = "联系人", inbox = "收件箱" }

struct CollaborationView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var section = CollaborationSection.tasks
    @State private var query = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if store.connections.isEmpty {
                        EmptyState(title: "协作从连接开始", message: "添加 Agent 后，联系人、协作事项和收件箱会汇集在这里。", systemImage: "person.2")
                    } else {
                        AgentPicker()
                        Picker("查看内容", selection: $section) { ForEach(CollaborationSection.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                        WorkspaceFeedback()
                        if let last = snapshot?.time {
                            Label("最近同步 " + Date(timeIntervalSince1970: last / 1000).formatted(date: .abbreviated, time: .shortened), systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
                        }
                        if snapshot == nil {
                            EmptyState(title: "等待首次同步", message: "完成本机配对后，Agent 开放的数据会显示在这里。", systemImage: "arrow.triangle.2.circlepath")
                            Button("查看连接设置") { store.tab = 0 }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                        } else {
                            switch section { case .tasks: tasks; case .contacts: contacts; case .inbox: inbox }
                            if let data = snapshot?.data { SnapshotDetails(data: data) }
                        }
                    }
                }.padding(20).frame(maxWidth: 920).frame(maxWidth: .infinity)
            }.background(Color.listBackground)
                .refreshable { await store.refresh(schedule: true) }
                .navigationTitle("协作")
                .toolbar { ToolbarItem { Button { Task { await store.invoke(method) } } label: { Label("读取最新内容", systemImage: "arrow.clockwise") }.disabled(!store.available(method) || store.busy != nil || store.demo) } }
        }
    }
    private var method: RPCMethod {
        switch section { case .tasks: return .collaborationState; case .contacts: return .contactsList; case .inbox: return .inboxList }
    }
    private var snapshot: WorkspaceSnapshot? {
        store.workspace?.snapshots[method.rawValue] ?? ((section != .tasks) ? store.workspace?.snapshots["collaboration.state"] : nil)
    }
    private var tasks: some View {
        VStack(alignment: .leading, spacing: 16) {
            let data = store.collaboration
            let approvals = data.records("pending_confirmations")
            if !approvals.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Label("\(approvals.count) 项需要你确认", systemImage: "hand.raised.fill").font(.headline).foregroundStyle(Color.statusWarning)
                    Text("请在 Agent 的原生渠道核对并回应。这里的状态会随处理进展更新。").font(.subheadline).foregroundStyle(.secondary)
                    ForEach(Array(approvals.enumerated()), id: \.offset) { _, approval in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(approval.string("question")).textSelection(.enabled)
                                if !remoteDate(approval["expires_at"]).isEmpty { Text("截止：" + remoteDate(approval["expires_at"])).font(.caption).foregroundStyle(.secondary) }
                            }.padding(.top, 10)
                        } label: { VStack(alignment: .leading, spacing: 5) { Text(approval.string("subject_id", default: "待确认请求")).font(.subheadline.bold()); RemoteStatus(status: approval.string("status")) } }
                    }
                }.padding(18).background(Color.statusWarning.opacity(0.09), in: RoundedRectangle(cornerRadius: 20))
            }
            let records = data.records("tasks")
            let operations = data.records("operations")
            if records.isEmpty && approvals.isEmpty && operations.isEmpty { EmptyState(title: "暂时没有协作事项", message: "交给 Agent 的协作事项和待确认请求，会在这里汇集。", systemImage: "checklist") }
            ForEach(Array(records.enumerated()), id: \.offset) { _, task in
                WorkspaceCard {
                    VStack(alignment: .leading, spacing: 14) {
                        let scope = task.record("scope")
                        HStack(alignment: .top) { Text(scope.string("purpose", default: task.string("task_id"))).font(.headline); Spacer(); RemoteStatus(status: task.string("status")) }
                        if !scope.string("topic").isEmpty { Text(scope.string("topic")).font(.subheadline).foregroundStyle(.secondary) }
                        let participants = scope.strings("participant_ids")
                        if !participants.isEmpty { Label(participants.joined(separator: "、"), systemImage: "person.2").font(.caption).foregroundStyle(.secondary) }
                        if !remoteDate(scope["expires_at"]).isEmpty { Text("有效期至 " + remoteDate(scope["expires_at"])).font(.caption).foregroundStyle(.secondary) }
                        ForEach(Array(operations.filter { $0.string("task_id") == task.string("task_id") }.enumerated()), id: \.offset) { _, operation in OperationView(operation: operation) }
                    }
                }
            }
            let orphaned = operations.filter { operation in !records.contains { $0.string("task_id") == operation.string("task_id") } }
            ForEach(Array(orphaned.enumerated()), id: \.offset) { _, operation in WorkspaceCard { OperationView(operation: operation) } }
        }
    }
    private var contacts: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !store.contacts.isEmpty {
                HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("搜索姓名、别名或 URN", text: $query).autocorrectionDisabled() }.padding(14).background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 14))
            }
            let visible = store.contacts.filter { query.isEmpty || ($0.string("contact_id") + " " + $0.string("alias") + " " + $0.string("urn") + " " + $0.strings("aliases").joined(separator: " ")).localizedCaseInsensitiveContains(query) }
            if visible.isEmpty { EmptyState(title: query.isEmpty ? "联系人会出现在这里" : "没有匹配的联系人", message: query.isEmpty ? "在 Agent 原生对话中确认联系人后，会自动同步到这里。" : "试试其他姓名、别名或 URN。", systemImage: "person.crop.circle.badge.plus") }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280))], spacing: 12) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, contact in
                    WorkspaceCard {
                        let name = contact.string("alias").isEmpty ? (contact.strings("aliases").first ?? contact.string("contact_id", default: "联系人")) : contact.string("alias")
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { AgentAvatar(name: name, size: 38); Text(name).font(.headline); Spacer() }
                            Text(contact.string("urn")).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            if !contact.string("urn").isEmpty { CopyLabel(value: contact.string("urn"), title: "复制 URN") }
                        }
                    }
                }
            }
        }
    }
    private var inbox: some View {
        VStack(alignment: .leading, spacing: 14) {
            if store.inbox.isEmpty { EmptyState(title: "收件箱很安静", message: "来自已确认联系人的消息，会在这里显示。", systemImage: "tray") }
            else { Text("来自其他 Agent 的消息；涉及你的授权，请在原生渠道确认。").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(store.inbox.reversed().enumerated()), id: \.offset) { _, message in
                WorkspaceCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) {
                            Image(systemName: "arrow.down.left").foregroundStyle(Color.brandPrimary)
                            Text(message.string("sender_urn", default: "对端 Agent")).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        Text(inboxText(message.string("text"))).textSelection(.enabled).lineSpacing(4)
                        HStack { Text(remoteDate(message["received_at"])); Spacer(); if !message.string("task_id").isEmpty { Text("事项 · " + message.string("task_id")) } }.font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    private func inboxText(_ value: String) -> String {
        if let data = value.data(using: .utf8), let record = try? JSONDecoder().decode(RemoteRecord.self, from: data), record.string("protocol") == "agent-comm-collaboration/v1", !record.string("text").isEmpty { return record.string("text") }
        return value.isEmpty ? "这条消息未提供文本内容。" : value
    }
}
struct OperationView: View {
    let operation: RemoteRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RemoteStatus(status: operation.string("status"))
            Text(operation.string("text")).font(.subheadline).textSelection(.enabled)
            if operation.string("status") == "accepted" { Text("本机队列已接收；尚不代表对方同意或事项完成。").font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(Color.listBackground, in: RoundedRectangle(cornerRadius: 14))
    }
}
