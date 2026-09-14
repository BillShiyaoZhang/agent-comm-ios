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
    @FocusState private var focusedField: Field?

    private enum Field { case server, email, password, confirmation }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if didRegister {
                    WorkspaceCard {
                        VStack(spacing: 20) {
                            EmptyState(title: "账户已创建", message: "请使用新账户登录这个工作区。", systemImage: "checkmark.circle")
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
                    if let errorMessage {
                        InlineNotice(message: errorMessage, style: .error)
                    }
                    WorkspaceCard {
                        VStack(alignment: .leading, spacing: 20) {
                            WorkspaceField(title: "工作区地址") {
                                TextField("https://workspace.example.com", text: $serverUrl)
                                    .crossPlatformKeyboardType(.url)
                                    .crossPlatformAutocapitalization()
                                    .autocorrectionDisabled()
                                    .workspaceInputStyle()
                                    .focused($focusedField, equals: .server)
                                    .submitLabel(.next)
                                    .onSubmit { focusedField = .email }
                            }
                            WorkspaceField(title: "邮箱") {
                                TextField("you@example.com", text: $email)
                                    .textContentType(.username)
                                    .crossPlatformKeyboardType(.emailAddress)
                                    .crossPlatformAutocapitalization()
                                    .autocorrectionDisabled()
                                    .workspaceInputStyle()
                                    .focused($focusedField, equals: .email)
                                    .submitLabel(.next)
                                    .onSubmit { focusedField = .password }
                            }
                            WorkspaceField(title: "密码", hint: "至少 8 个字符。") {
                                SecureField("设置账户密码", text: $password)
                                    .textContentType(.newPassword)
                                    .workspaceInputStyle()
                                    .focused($focusedField, equals: .password)
                                    .submitLabel(.next)
                                    .onSubmit { focusedField = .confirmation }
                            }
                            WorkspaceField(title: "确认密码") {
                                SecureField("再次输入密码", text: $confirmPassword)
                                    .textContentType(.newPassword)
                                    .workspaceInputStyle()
                                    .focused($focusedField, equals: .confirmation)
                                    .submitLabel(.go)
                                    .onSubmit(handleRegister)
                            }
                            Button(action: handleRegister) {
                                HStack(spacing: 8) {
                                    if isLoading { ProgressView().tint(.white) }
                                    Text(isLoading ? "正在创建…" : "创建账户")
                                }
                            }
                            .buttonStyle(WorkspacePrimaryButtonStyle())
                        }
                        .disabled(isLoading)
                    }
                    Text("创建成功后返回登录。不同工作区的账户不会自动互通。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 520)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Color.listBackground)
        .navigationTitle("创建账户")
        .crossPlatformNavigationBarTitleDisplayModeInline()
        .onAppear {
            if serverUrl.isEmpty { serverUrl = serverURL ?? networkManager.baseUrl }
        }
    }

    private func handleRegister() {
        guard !isLoading else { return }
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEmail.isEmpty else {
            errorMessage = "请填写邮箱。"
            focusedField = .email
            return
        }
        guard password.count >= 8 else {
            errorMessage = "密码需要至少 8 个字符。"
            focusedField = .password
            return
        }
        guard password == confirmPassword else {
            errorMessage = "两次输入的密码不一致，请重新确认。"
            focusedField = .confirmation
            return
        }
        do {
            try networkManager.configureServer(serverUrl)
            serverUrl = networkManager.baseUrl
        } catch {
            errorMessage = error.localizedDescription
            focusedField = .server
            return
        }
        focusedField = nil
        errorMessage = nil
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                try await networkManager.register(email: normalizedEmail, password: password)
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
