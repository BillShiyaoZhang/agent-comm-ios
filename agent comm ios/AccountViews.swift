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
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("邮箱", text: $email).textContentType(.emailAddress).crossPlatformKeyboardType(.emailAddress).crossPlatformAutocapitalization().autocorrectionDisabled()
                    Text(NetworkManager.shared.baseUrl).font(.caption).foregroundStyle(.secondary)
                    Button(mode == "reset" ? "发送重置邮件" : "重新发送验证邮件") { Task { await submit() } }.disabled(busy || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: { Text("若该邮箱符合条件，工作区会发送邮件。请在邮件链接中完成验证或重置密码。") }
                if busy { ProgressView() }
                if let result { InlineNotice(message: result, style: failure ? .error : .info) }
            }.navigationTitle(mode == "reset" ? "重置密码" : "验证邮箱")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(busy) } }
                .onAppear { email = initialEmail }
        }.interactiveDismissDisabled(busy).frame(minWidth: 300, idealWidth: 500, minHeight: 330)
    }
    private func submit() async {
        busy = true; result = nil; defer { busy = false }
        do {
            let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
            if mode == "reset" { try await NetworkManager.shared.requestPasswordReset(email: address) }
            else { try await NetworkManager.shared.resendVerification(email: address) }
            failure = false; result = "如果邮箱符合条件，邮件将发送到该地址。请检查收件箱和垃圾邮件。"
        } catch { failure = true; result = error.localizedDescription }
    }
}

struct AccountSecurityView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var account: RemoteRecord = [:]
    @State private var currentPassword = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var busy = false
    @State private var result: String?
    @State private var failed = false
    @State private var emailHelp = false
    var body: some View {
        Form {
            Section("邮箱状态") {
                Text(account.string("email", default: NetworkManager.shared.currentUser?.email ?? "")).textSelection(.enabled)
                Label(account.bool("emailVerified") ? "邮箱已验证" : "邮箱尚未验证", systemImage: account.bool("emailVerified") ? "checkmark.seal" : "envelope")
                if !account.bool("emailVerified") { Button("重新发送验证邮件") { emailHelp = true } }
            }
            Section {
                SecureField("当前密码", text: $currentPassword).textContentType(.password)
                SecureField("新密码（至少 8 个字符）", text: $password).textContentType(.newPassword)
                SecureField("确认新密码", text: $confirmation).textContentType(.newPassword)
                Button("发送改密确认邮件") { Task { await changePassword() } }.disabled(busy || currentPassword.isEmpty || password.count < 8 || password.utf8.count > 1024 || password != confirmation)
            } header: { Text("修改密码") } footer: { Text("新密码在邮件确认后生效，随后需要重新登录。密码不会保存到此设备。") }
            if let result { InlineNotice(message: result, style: failed ? .error : .info) }
            if busy { ProgressView() }
        }.navigationTitle("账户与安全").disabled(busy)
            .sheet(isPresented: $emailHelp) { EmailHelpView(mode: "verify", initialEmail: account.string("email")) }
            .task {
                do { let value = try await NetworkManager.shared.fetchAccount(); guard !Task.isCancelled else { return }; account = value }
                catch { failed = true; result = error.localizedDescription }
            }
            .onDisappear { currentPassword = ""; password = ""; confirmation = "" }
    }
    private func changePassword() async {
        busy = true; result = nil; defer { busy = false }
        do {
            _ = try await NetworkManager.shared.changePassword(currentPassword: currentPassword, password: password)
            currentPassword = ""; password = ""; confirmation = ""
            failed = false; result = "请检查邮箱中的改密确认链接。完成确认前，原密码仍有效。"
        } catch { failed = true; result = error.localizedDescription }
    }
}
