import SwiftUI

struct RegisterView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var networkManager = NetworkManager.shared
    var serverURL: String? = nil
    @State private var serverUrl = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isLoading = false
    @State private var didRegister = false
    @State private var errorMessage: String?
    @State private var errorField: Field?
    @FocusState private var focusedField: Field?
    @AccessibilityFocusState private var errorHasFocus: Bool

    private enum Field { case server, email, password, confirmation }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if didRegister {
                    WorkspaceCard {
                        VStack(spacing: 20) {
                            EmptyState(title: "请检查验证邮件", message: "若该邮箱可以注册，工作区会发送验证邮件。完成邮箱验证后再登录；已有账户可直接登录。", systemImage: "envelope.badge")
                            Button("返回登录") { dismiss() }
                                .buttonStyle(WorkspacePrimaryButtonStyle())
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("开始协作")
                            .font(.largeTitle.bold())
                        Text("在你的工作区中创建一个账户。")
                            .foregroundStyle(.secondary)
                    }
                    if let errorMessage, errorField == nil {
                        InlineNotice(message: errorMessage, style: .error)
                            .accessibilityFocused($errorHasFocus)
                    }
                    WorkspaceCard {
                        VStack(alignment: .leading, spacing: 20) {
                            WorkspaceField(title: "工作区地址") {
                                TextField("https://workspace.example.com", text: $serverUrl)
                                    .accessibilityLabel("工作区地址")
                                    .crossPlatformKeyboardType(.url)
                                    .crossPlatformAutocapitalization()
                                    .autocorrectionDisabled()
                                    .workspaceInputStyle()
                                    .focused($focusedField, equals: .server)
                                    .submitLabel(.next)
                                    .onSubmit { focusedField = .email }
                            }
                            fieldError(for: .server)
                            WorkspaceField(title: "邮箱") {
                                TextField("you@example.com", text: $email)
                                    .accessibilityLabel("邮箱")
                                    .textContentType(.username)
                                    .crossPlatformKeyboardType(.emailAddress)
                                    .crossPlatformAutocapitalization()
                                    .autocorrectionDisabled()
                                    .workspaceInputStyle()
                                    .focused($focusedField, equals: .email)
                                    .submitLabel(.next)
                                    .onSubmit { focusedField = .password }
                            }
                            fieldError(for: .email)
                            WorkspaceField(title: "密码", hint: "至少 8 个字符。") {
                                SecureField("设置账户密码", text: $password)
                                    .accessibilityLabel("密码")
                                    .textContentType(.newPassword)
                                    .workspaceInputStyle()
                                    .focused($focusedField, equals: .password)
                                    .submitLabel(.next)
                                    .onSubmit { focusedField = .confirmation }
                            }
                            fieldError(for: .password)
                            WorkspaceField(title: "确认密码") {
                                SecureField("再次输入密码", text: $confirmPassword)
                                    .accessibilityLabel("确认密码")
                                    .textContentType(.newPassword)
                                    .workspaceInputStyle()
                                    .focused($focusedField, equals: .confirmation)
                                    .submitLabel(.go)
                                    .onSubmit(handleRegister)
                            }
                            fieldError(for: .confirmation)
                            Button(action: handleRegister) {
                                HStack(spacing: 8) {
                                    if isLoading { ProgressView().tint(.white) }
                                    Text(isLoading ? "正在创建…" : "创建账户")
                                }
                            }
                            .buttonStyle(WorkspacePrimaryButtonStyle())
                            .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty || confirmPassword.isEmpty || serverUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .disabled(isLoading)
                    }
                    Text("创建成功后返回登录。不同工作区的账户不会自动互通。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    NavigationLink {
                        WorkspaceDataView()
                    } label: {
                        Label("数据与隐私", systemImage: "hand.raised").workspaceTapTarget()
                    }
                    .font(.subheadline)
                }
            }
            .frame(maxWidth: 520)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Color.listBackground)
        .workspaceScrollDismissesKeyboard()
        .navigationTitle("创建账户")
        .crossPlatformNavigationBarTitleDisplayModeInline()
        .onAppear {
            if serverUrl.isEmpty { serverUrl = serverURL ?? networkManager.baseUrl }
        }
        .onChange(of: errorMessage) { _, message in errorHasFocus = message != nil }
        .onDisappear { password = ""; confirmPassword = "" }
    }

    @ViewBuilder
    private func fieldError(for field: Field) -> some View {
        if errorField == field, let errorMessage {
            InlineNotice(message: errorMessage, style: .error)
                .accessibilityFocused($errorHasFocus)
        }
    }

    private func showError(_ message: String, field: Field) {
        errorField = field
        errorMessage = message
        focusedField = field
    }

    private func handleRegister() {
        guard !isLoading else { return }
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEmail.isEmpty else {
            showError("请填写邮箱。", field: .email)
            return
        }
        guard password.count >= 8 else {
            showError("密码需要至少 8 个字符。", field: .password)
            return
        }
        guard password.utf8.count <= 1024 else {
            showError("密码过长，请缩短后重试。", field: .password)
            return
        }
        guard password == confirmPassword else {
            showError("两次输入的密码不一致，请重新确认。", field: .confirmation)
            return
        }
        do {
            try networkManager.configureServer(serverUrl)
            serverUrl = networkManager.baseUrl
        } catch {
            showError(error.localizedDescription, field: .server)
            return
        }
        focusedField = nil
        errorMessage = nil
        errorField = nil
        isLoading = true
        let submittedPassword = password
        Task {
            defer { isLoading = false }
            do {
                try await networkManager.register(email: normalizedEmail, password: submittedPassword)
                password = ""
                confirmPassword = ""
                didRegister = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview { NavigationStack { RegisterView() } }
