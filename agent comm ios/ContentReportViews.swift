import SwiftUI
import AgentWorkspaceKit

private struct ReportTarget: Identifiable {
    let context: AgentSharingContext
    let kind: String
    let recordID: String
    let id = UUID()
}

struct ContentReportButton: View {
    @EnvironmentObject private var store: WorkspaceStore
    let kind: String
    let recordID: String
    @State private var target: ReportTarget?
    var body: some View {
        if isStableID(recordID) {
            Button {
                if let context = store.sharingContext { target = ReportTarget(context: context, kind: kind, recordID: recordID) }
            } label: { Label("举报此内容", systemImage: "flag").workspaceTapTarget() }
                .font(.caption).buttonStyle(.bordered).disabled(store.sharingContext == nil)
                .sheet(item: $target) { ContentReportForm(target: $0) }
        }
    }
}

private struct ContentReportForm: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var network = NetworkManager.shared
    let target: ReportTarget
    @State private var reportID = UUID().uuidString.lowercased()
    @State private var preview: RemoteRecord?
    @State private var reason = "harassment"
    @State private var comment = ""
    @State private var attachEvidence = false
    @State private var consent = false
    @State private var loading = false
    @State private var uncertain = false
    @State private var savedRequest: RemoteRecord?
    @State private var report: RemoteRecord?
    @State private var feedback: String?
    @State private var recoveryFailed = false
    @AccessibilityFocusState private var feedbackFocused: Bool

    private var current: Bool { store.sharingContext == target.context }
    private var journal: SecureStore { SecureStore(namespace: WorkspaceStore.recoveryNamespace(server: target.context.server, userID: target.context.accountID)) }
    private var journalKey: String { "content-report." + target.context.agentID + "." + target.kind + "." + target.recordID }
    private let reasons = [("harassment", "骚扰或欺凌"), ("hate", "仇恨或歧视"), ("sexual", "色情或不当性内容"), ("violence", "暴力或威胁"), ("spam", "垃圾信息或诈骗"), ("other", "其他")]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if current {
                    Text("提交给此工作区的内容处理人员").font(.headline)
                    Text(target.context.server).font(.caption).textSelection(.enabled)
                    Text("Agent：" + target.context.agentName).font(.subheadline)
                    Text("记录：" + target.recordID).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    if let report { ContentReportReceipt(report: report) }
                    else if uncertain {
                        Text("原举报编号：" + reportID).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Text("回执尚未核实，原请求已保存在本设备。关闭后可从同一内容继续核实，也可在设置中查看举报记录。").font(.subheadline)
                        Button { Task { await verify() } } label: { Text("按原编号核实").workspaceTapTarget() }.buttonStyle(.bordered)
                        if savedRequest != nil {
                            Button { Task { await submit(retry: true) } } label: { Text("重试同一举报").workspaceTapTarget() }.buttonStyle(.bordered)
                        }
                    } else if !recoveryFailed {
                        Picker("举报原因", selection: $reason) { ForEach(reasons, id: \.0) { item in Text(item.1).tag(item.0) } }
                        WorkspaceField(title: "补充说明（可选）", hint: "请简要说明问题，勿填入密码、私钥或与此举报无关的个人资料。") {
                            TextField("说明涉及的问题", text: $comment, axis: .vertical).lineLimit(3...8).workspaceInputStyle()
                        }
                        if comment.utf8.count > 2000 { InlineNotice(message: "补充说明过长，请缩短后提交。", style: .error) }
                        if let preview {
                            Text("本次可附的确切证据").font(.subheadline.bold())
                            if preview.string("evidence").isEmpty {
                                Text("此记录没有可附的已获准正文。本次仍可提交记录标识和你的说明。").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text(preview.string("evidence")).font(.subheadline).textSelection(.enabled)
                                Toggle("附上以上证据片段", isOn: $attachEvidence)
                            }
                            Text("只提交这个记录的标识、原因、说明及你选择的证据片段。处理人员可以核查举报；不会自动附上整段聊天或联系对端。").font(.caption).foregroundStyle(.secondary)
                            Toggle("我同意将本次举报交给工作区处理人员", isOn: $consent)
                            Button { Task { await submit() } } label: { Text("提交举报").frame(maxWidth: .infinity).workspaceTapTarget() }
                                .buttonStyle(WorkspacePrimaryButtonStyle()).disabled(!consent || comment.utf8.count > 2000)
                        }
                    }
                    if let feedback { InlineNotice(message: feedback, style: uncertain ? .info : .error).accessibilityFocused($feedbackFocused) }
                    if loading { ProgressView("正在核实…") }
                    } else { InlineNotice(message: "账户、工作区或 Agent 已变化，请关闭后重新打开。", style: .error) }
                }.padding(20).disabled(loading || !current)
            }.background(Color.listBackground).navigationTitle("举报内容")
                .crossPlatformNavigationBarTitleDisplayModeInline()
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(loading && current) } }
        }.interactiveDismissDisabled(loading && current)
            .task { await prepare() }
            .onChange(of: reason) { _, _ in consent = false }
            .onChange(of: comment) { _, _ in consent = false }
            .onChange(of: attachEvidence) { _, _ in consent = false }
    }

    private func prepare() async {
        guard current else { return }
        loading = true; defer { loading = false }
        do {
            if let data = try journal.data(key: journalKey) {
                let restored = try JSONDecoder().decode(RemoteRecord.self, from: data)
                guard let id = restored["reportId"]?.stringValue, UUID(uuidString: id) != nil,
                      restored.string("agentId") == target.context.agentID,
                      restored.record("target").string("kind") == target.kind,
                      restored.record("target").string("id") == target.recordID else { throw WorkspaceClientError.invalidResponse }
                reportID = id; savedRequest = restored; uncertain = true
            } else {
                let value = try await network.previewContentReport(reportID: reportID, agentID: target.context.agentID, kind: target.kind, recordID: target.recordID)
                guard current else { return }
                preview = value
            }
        } catch { recoveryFailed = true; feedback = "暂时无法准备或恢复举报；本次未继续提交。" + error.localizedDescription; feedbackFocused = true }
    }
    private func submit(retry: Bool = false) async {
        guard current, !loading else { return }
        let priorUncertainty = uncertain || retry
        let body: RemoteRecord
        if retry, let savedRequest { body = savedRequest }
        else {
            guard consent, let preview, comment.utf8.count <= 2000 else { return }
            body = ["reportId": .string(reportID), "agentId": .string(target.context.agentID),
                    "target": ["kind": .string(target.kind), "id": .string(target.recordID)], "reason": .string(reason), "comment": .string(comment),
                    "evidence": .string(attachEvidence ? preview.string("evidence") : ""), "previewToken": .string(preview.string("previewToken")), "consent": true]
        }
        loading = true; feedback = nil; defer { loading = false }
        do {
            try journal.set(JSONEncoder().encode(body), for: journalKey)
            savedRequest = body
        } catch { feedback = "无法安全保存原举报，本次尚未提交。" + error.localizedDescription; feedbackFocused = true; return }
        guard current else { return }
        do {
            let value = try await network.submitContentReport(reportID: reportID, agentID: target.context.agentID, kind: target.kind, recordID: target.recordID,
                reason: body.string("reason"), comment: body.string("comment"), evidence: body.string("evidence"), previewToken: body.string("previewToken"))
            guard current else { return }
            report = value; uncertain = false
            try? journal.remove(key: journalKey)
        } catch let failure as ContentReportError {
            guard current else { return }
            uncertain = failure.uncertain || priorUncertainty; feedback = failure.localizedDescription; feedbackFocused = true
            if !uncertain {
                do { try journal.remove(key: journalKey); savedRequest = nil }
                catch { recoveryFailed = true; feedback = "举报已明确拒绝，但原记录清理未完成，请稍后核实。" }
                consent = false
            }
        } catch {
            guard current else { return }
            uncertain = true; feedback = "提交结果待核实，请保留原编号。" + error.localizedDescription; feedbackFocused = true
        }
    }
    private func verify() async {
        guard current, !loading else { return }
        loading = true; defer { loading = false }
        do {
            let value = try await network.fetchContentReport(reportID: reportID)
            guard current else { return }
            guard value.string("agentId") == target.context.agentID,
                  value.record("target").string("kind") == target.kind,
                  value.record("target").string("id") == target.recordID,
                  savedRequest == nil || value.string("reason") == savedRequest?.string("reason") else { throw WorkspaceClientError.invalidResponse }
            report = value; uncertain = false; try? journal.remove(key: journalKey)
        } catch { if current { feedback = "尚未核实原举报，请稍后查看记录或联系工作区。" + error.localizedDescription; feedbackFocused = true } }
    }
}

private struct ContentReportReceipt: View {
    let report: RemoteRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(["pending": "举报已收到 · 等待处理", "reviewing": "正在核查", "resolved": "已处理", "dismissed": "核查已结束"][report.string("status")] ?? "状态待核实").font(.headline)
            Text("举报编号：" + report.string("id")).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            if !report.string("response").isEmpty { Text(report.string("response")).font(.subheadline).textSelection(.enabled) }
        }
    }
}

struct ContentReportsView: View {
    @ObservedObject private var network = NetworkManager.shared
    @State private var reports: [RemoteRecord] = []
    @State private var loading = false
    @State private var error: String?
    @State private var displayedScope = ""
    private var scope: String { network.baseUrl + "\u{0}" + (network.currentUser?.id ?? "signed-out") + "\u{0}" + String(network.sessionRevision) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("当前账户最近 20 项举报；查看记录不会重新提交。").font(.caption).foregroundStyle(.secondary)
                if let error { InlineNotice(message: error, style: .error) }
                if loading { ProgressView("读取举报记录…") }
                if !loading && reports.isEmpty && error == nil { Text("暂无举报记录。") }
                if network.isAuthenticated && displayedScope == scope {
                    ForEach(socialRecordRows(reports, key: "id")) { row in WorkspaceCard { ContentReportReceipt(report: row.data) } }
                }
                Button { Task { await load() } } label: { Text("刷新处理状态").workspaceTapTarget() }.buttonStyle(.bordered).disabled(loading || !network.isAuthenticated)
            }.padding(20)
        }.background(Color.listBackground).navigationTitle("举报记录")
            .task(id: network.sessionRevision) { reports = []; await load() }
    }
    private func load() async {
        guard network.isAuthenticated, !loading else { return }
        let revision = network.sessionRevision, requestedScope = scope
        loading = true; error = nil; defer { loading = false }
        do {
            let value = try await network.fetchContentReports()
            guard network.isAuthenticated, network.sessionRevision == revision, scope == requestedScope else { return }
            reports = value; displayedScope = requestedScope
        } catch { if network.sessionRevision == revision { self.error = error.localizedDescription } }
    }
}
