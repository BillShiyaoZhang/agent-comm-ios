import SwiftUI
import AgentWorkspaceKit

struct EmailHelpView: View {
    var mode: String
    var initialEmail = ""
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var busy = false
    @State private var result: String?
    @State private var failure = false
    @FocusState private var emailIsFocused: Bool
    @AccessibilityFocusState private var resultHasFocus: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    WorkspaceField(title: "邮箱") {
                        TextField("you@example.com", text: $email)
                            .accessibilityLabel("邮箱")
                            .textContentType(.emailAddress)
                            .crossPlatformKeyboardType(.emailAddress)
                            .crossPlatformAutocapitalization()
                            .autocorrectionDisabled()
                            .focused($emailIsFocused)
                            .submitLabel(.send)
                            .onSubmit { sendEmail() }
                    }
                    Text(NetworkManager.shared.baseUrl)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button { sendEmail() } label: {
                        Text(mode == "reset" ? "发送重置邮件" : "重新发送验证邮件").workspaceTapTarget()
                    }
                    .disabled(busy || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text("若该邮箱符合条件，工作区会发送邮件。请在邮件链接中完成验证或重置密码。")
                }
                .disabled(busy)
                if busy { ProgressView("正在请求邮件…") }
                if let result {
                    InlineNotice(message: result, style: failure ? .error : .info)
                        .accessibilityFocused($resultHasFocus)
                }
            }
            .navigationTitle(mode == "reset" ? "重置密码" : "验证邮箱")
            .workspaceScrollDismissesKeyboard()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.disabled(busy)
                }
            }
            .onAppear { email = initialEmail }
            .onChange(of: result) { _, message in resultHasFocus = message != nil }
        }
        .interactiveDismissDisabled(busy)
        .frame(minWidth: 300, idealWidth: 500, minHeight: 330)
    }

    private func sendEmail() {
        guard !busy, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        emailIsFocused = false
        // Set this before starting the task so a second tap cannot enqueue another request.
        busy = true
        result = nil
        Task { await submit() }
    }

    private func submit() async {
        defer { busy = false }
        do {
            let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
            if mode == "reset" { try await NetworkManager.shared.requestPasswordReset(email: address) }
            else { try await NetworkManager.shared.resendVerification(email: address) }
            failure = false
            result = "如果邮箱符合条件，邮件将发送到该地址。请检查收件箱和垃圾邮件。"
        } catch {
            failure = true
            result = error.localizedDescription
        }
    }
}

struct AccountSecurityView: View {
    @State private var account: RemoteRecord?
    @State private var currentPassword = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var loadingAccount = false
    @State private var accountError: String?
    @State private var busy = false
    @State private var result: String?
    @State private var failed = false
    @State private var resultField: Field?
    @State private var emailHelp = false
    @State private var deleteAccount = false
    @FocusState private var focusedField: Field?
    @AccessibilityFocusState private var resultHasFocus: Bool

    private enum Field { case currentPassword, password, confirmation }

    var body: some View {
        Form {
            Section("邮箱状态") {
                Text(account?.string("email", default: NetworkManager.shared.currentUser?.email ?? "") ?? NetworkManager.shared.currentUser?.email ?? "")
                    .textSelection(.enabled)
                if loadingAccount {
                    ProgressView("正在读取邮箱状态…")
                } else if let account {
                    Label(account.bool("emailVerified") ? "邮箱已验证" : "邮箱尚未验证", systemImage: account.bool("emailVerified") ? "checkmark.seal" : "envelope")
                    if !account.bool("emailVerified") {
                        Button { emailHelp = true } label: {
                            Text("重新发送验证邮件").workspaceTapTarget()
                        }
                    }
                } else if let accountError {
                    InlineNotice(message: accountError, style: .error)
                    Button { Task { await loadAccount() } } label: {
                        Label("重新读取邮箱状态", systemImage: "arrow.clockwise").workspaceTapTarget()
                    }
                }
            }
            Section {
                WorkspaceField(title: "当前密码") {
                    SecureField("输入当前账户密码", text: $currentPassword)
                        .accessibilityLabel("当前密码")
                        .textContentType(.password)
                        .focused($focusedField, equals: .currentPassword)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }
                }
                fieldError(for: .currentPassword)
                WorkspaceField(title: "新密码", hint: "至少 8 个字符。") {
                    SecureField("输入新密码", text: $password)
                        .accessibilityLabel("新密码")
                        .textContentType(.newPassword)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .confirmation }
                }
                fieldError(for: .password)
                WorkspaceField(title: "确认新密码") {
                    SecureField("再次输入新密码", text: $confirmation)
                        .accessibilityLabel("确认新密码")
                        .textContentType(.newPassword)
                        .focused($focusedField, equals: .confirmation)
                        .submitLabel(.send)
                        .onSubmit { requestPasswordChange() }
                }
                fieldError(for: .confirmation)
                Button { requestPasswordChange() } label: {
                    Text(busy ? "正在发送…" : "发送改密确认邮件").workspaceTapTarget()
                }
                .disabled(currentPassword.isEmpty || password.isEmpty || confirmation.isEmpty)
            } header: {
                Text("修改密码")
            } footer: {
                Text("新密码在邮件确认后生效，随后需要重新登录。密码不会保存到此设备。")
            }
            if let result, resultField == nil {
                InlineNotice(message: result, style: failed ? .error : .info)
                    .accessibilityFocused($resultHasFocus)
            }
            if busy { ProgressView("正在请求改密邮件…") }
            Section {
                Button(role: .destructive) { deleteAccount = true } label: {
                    Label("删除账户", systemImage: "trash").workspaceTapTarget()
                }
            } footer: {
                Text("删除当前工作区账户及保存的数据。请先阅读删除范围并核实尚未完成的远程操作。")
            }
        }
        .navigationTitle("账户与安全")
        .workspaceScrollDismissesKeyboard()
        .disabled(busy)
        .sheet(isPresented: $emailHelp) {
            EmailHelpView(mode: "verify", initialEmail: account?.string("email") ?? "")
        }
        .sheet(isPresented: $deleteAccount) { DeleteAccountView() }
        .task { await loadAccount() }
        .onChange(of: result) { _, message in resultHasFocus = message != nil }
        .onDisappear { currentPassword = ""; password = ""; confirmation = "" }
    }

    @ViewBuilder
    private func fieldError(for field: Field) -> some View {
        if resultField == field, let result {
            InlineNotice(message: result, style: .error)
                .accessibilityFocused($resultHasFocus)
        }
    }

    private func showError(_ message: String, field: Field) {
        failed = true
        resultField = field
        result = message
        focusedField = field
    }

    private func loadAccount() async {
        guard !loadingAccount else { return }
        loadingAccount = true
        accountError = nil
        defer { loadingAccount = false }
        do {
            let value = try await NetworkManager.shared.fetchAccount()
            guard !Task.isCancelled else { return }
            account = value
        } catch {
            guard !Task.isCancelled else { return }
            accountError = error.localizedDescription
        }
    }

    private func requestPasswordChange() {
        guard !busy else { return }
        guard !currentPassword.isEmpty else {
            showError("请填写当前密码。", field: .currentPassword)
            return
        }
        guard password.count >= 8 else {
            showError("新密码需要至少 8 个字符。", field: .password)
            return
        }
        guard password.utf8.count <= 1024 else {
            showError("新密码过长，请缩短后重试。", field: .password)
            return
        }
        guard password == confirmation else {
            showError("两次输入的新密码不一致，请重新确认。", field: .confirmation)
            return
        }
        focusedField = nil
        busy = true
        result = nil
        resultField = nil
        let submittedCurrentPassword = currentPassword
        let submittedPassword = password
        Task { await changePassword(currentPassword: submittedCurrentPassword, newPassword: submittedPassword) }
    }

    private func changePassword(currentPassword submittedCurrentPassword: String, newPassword submittedPassword: String) async {
        defer { busy = false }
        do {
            _ = try await NetworkManager.shared.changePassword(currentPassword: submittedCurrentPassword, password: submittedPassword)
            currentPassword = ""; password = ""; confirmation = ""
            failed = false
            result = "请检查邮箱中的改密确认链接。完成确认前，原密码仍有效。"
        } catch {
            failed = true
            result = error.localizedDescription
        }
    }
}

struct DeleteAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var acknowledgesScope = false
    @State private var confirm = false
    @State private var busy = false
    @State private var uncertain = false
    @State private var result: String?
    @FocusState private var passwordIsFocused: Bool
    @AccessibilityFocusState private var resultHasFocus: Bool
    private let server = NetworkManager.shared.baseUrl
    private let user = NetworkManager.shared.currentUser

    var body: some View {
        NavigationStack {
            Form {
                Section("当前账户") {
                    LabeledContent("邮箱", value: user?.email ?? "未登录")
                    Text(server).font(.footnote).textSelection(.enabled)
                    Link("阅读工作区隐私政策", destination: URL(string: server)!.appendingPathComponent("privacy"))
                }
                Section("删除范围") {
                    Text("删除这个工作区中的账户、控制台身份、连接、保存的对话与协作副本、草稿、提醒和账户设置。其他设备上的登录会失效。此设备的会话、草稿与发送恢复记录会在收到删除成功后清除。")
                    Text("已派发的请求可能继续执行。Agent 本机数据与配对、平台中的记录、接收方或已配置 AI 服务持有的内容，以及运营者的日志和备份，无法通过此操作撤回。请先在 Agent 本机停止任务、撤销配对，并向相应运营者了解其删除方式。")
                    Text("删除完成后无法恢复账户及工作区中的保存数据。")
                }
                Section {
                    WorkspaceField(title: "当前密码", hint: "用于验证你有权删除此账户。") {
                        SecureField("输入当前账户密码", text: $password)
                            .textContentType(.password)
                            .focused($passwordIsFocused)
                            .submitLabel(.done)
                            .onSubmit { passwordIsFocused = false }
                    }
                    Toggle("我已阅读删除范围，理解此操作无法恢复", isOn: $acknowledgesScope)
                    Button(role: .destructive) {
                        passwordIsFocused = false
                        confirm = true
                    } label: {
                        Text("删除此工作区账户…").workspaceTapTarget()
                    }
                    .disabled(password.isEmpty || password.utf8.count > 1024 || !acknowledgesScope || uncertain || user == nil)
                }
                .disabled(busy)
                if busy { ProgressView("正在删除账户，请等待明确结果…") }
                if let result {
                    InlineNotice(message: result, style: .error).accessibilityFocused($resultHasFocus)
                }
                if uncertain {
                    Text("本页已停止再次提交删除。可关闭本页，核实登录状态，或联系当前工作区运营者。登录失效本身不能证明所有数据已删除。")
                        .font(.footnote)
                }
            }
            .navigationTitle("删除账户")
            .workspaceScrollDismissesKeyboard()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
            }
            .confirmationDialog("永久删除此工作区账户？", isPresented: $confirm, titleVisibility: .visible) {
                Button("永久删除账户", role: .destructive) { submitDeletion() }
                Button("取消", role: .cancel) { }
            } message: {
                Text("\(user?.email ?? "")\n\(server)\n账户及这个工作区中的保存数据将无法恢复。")
            }
        }
        .interactiveDismissDisabled(busy)
        .frame(minWidth: 300, idealWidth: 540, minHeight: 420)
        .onChange(of: result) { _, message in resultHasFocus = message != nil }
        .onDisappear { password = "" }
    }

    private func submitDeletion() {
        guard !busy, !uncertain, acknowledgesScope, let user, !password.isEmpty, password.utf8.count <= 1024 else { return }
        busy = true
        result = nil
        let submittedPassword = password
        password = ""
        Task {
            defer { busy = false }
            do {
                try await NetworkManager.shared.deleteAccount(currentPassword: submittedPassword, expectedServer: server, expectedUserID: user.id)
                dismiss()
            } catch {
                uncertain = (error as? AccountDeletionError)?.uncertain ?? false
                result = error.localizedDescription
            }
        }
    }
}

/// Client behavior and a link to the current workspace operator's published policy.
struct WorkspaceDataView: View {
    var body: some View {
        Form {
            Section("工作区隐私政策") {
                Text(NetworkManager.shared.baseUrl).font(.footnote).textSelection(.enabled)
                Link("查看隐私政策", destination: URL(string: NetworkManager.shared.baseUrl)!.appendingPathComponent("privacy"))
                Text("自托管工作区的数据处理由该工作区运营者负责，请核对当前地址对应的政策。")
            }
            Section("发送到工作区的数据") {
                Text("登录和账户操作会将邮箱及验证所需的信息发送到你指定的工作区。你发起的消息、协作与智能体操作也会发送到该工作区。")
                Text("工作区的运营者负责服务端的数据处理。使用前请向运营者了解隐私政策、数据保留和删除方式，以及智能体的数据访问范围。")
            }
            Section("此设备保存的数据") {
                Text("工作区地址保存在此设备。登录会话凭据保存在系统钥匙串，并按工作区地址区分。应用不会保存你的账户密码；系统密码自动填充由你管理。")
                Text("尚未同步的对话草稿和待核实的发送记录也会保存在系统钥匙串中，并按工作区和账户隔离，用于恢复编辑和核实发送结果。草稿会在应用打开时同步到工作区账户。")
            }
            Section("退出登录") {
                Text("退出登录会清除当前工作区在此设备上的登录会话凭据。工作区中的账户、消息与协作记录仍会保留。本机草稿与发送恢复记录也会保留，重新登录同一账户后可继续恢复。")
            }
            Section("删除账户") {
                Text("登录后可在“设置 → 账户与安全 → 删除账户”发起删除。操作前会显示当前工作区及删除范围，并要求当前密码和明确确认。")
            }
        }
        .navigationTitle("数据与隐私")
        .crossPlatformNavigationBarTitleDisplayModeInline()
    }
}
