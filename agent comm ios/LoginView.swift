import SwiftUI

struct LoginView: View {
    @ObservedObject private var networkManager = NetworkManager.shared
    @State private var email = ""
    @State private var password = ""
    @State private var serverUrl = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showRegister = false
    @FocusState private var focusedField: Field?

    private enum Field { case server, email, password }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.largeTitle)
                            .foregroundStyle(Color.brandPrimary)
                            .padding(16)
                            .background(Color.brandPrimary.opacity(0.1), in: RoundedRectangle(cornerRadius: 20))
                            .accessibilityHidden(true)
                        Text("连接你的工作区")
                            .font(.largeTitle.bold())
                        Text("查看智能体、处理协作消息，让需要你决定的事及时向前。")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let errorMessage {
                        InlineNotice(message: errorMessage, style: .error)
                    }

                    WorkspaceCard {
                        VStack(alignment: .leading, spacing: 20) {
                            WorkspaceField(title: "工作区地址", hint: "使用已部署的工作区地址。连接电脑上的服务时，请填写电脑的局域网地址。") {
                                TextField("https://workspace.example.com", text: $serverUrl)
                                    .crossPlatformKeyboardType(.url)
                                    .crossPlatformAutocapitalization()
                                    .autocorrectionDisabled()
                                    .workspaceInputStyle()
                                    .focused($focusedField, equals: .server)
                                    .submitLabel(.next)
                                    .onSubmit { focusedField = .email }
                            }

                            Divider()

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
                            WorkspaceField(title: "密码") {
                                SecureField("输入账户密码", text: $password)
                                    .textContentType(.password)
                                    .workspaceInputStyle()
                                    .focused($focusedField, equals: .password)
                                    .submitLabel(.go)
                                    .onSubmit(handleLogin)
                            }
                            Button(action: handleLogin) {
                                HStack(spacing: 8) {
                                    if isLoading { ProgressView().tint(.white) }
                                    Text(isLoading ? "正在登录…" : "登录工作区")
                                }
                            }
                            .buttonStyle(WorkspacePrimaryButtonStyle())
                            .disabled(isLoading)
                        }
                        .disabled(isLoading)
                    }

                    Button(action: openRegistration) {
                        Text("还没有账户？创建账户")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.brandPrimary)
                    .disabled(isLoading)

                    Label("账户属于当前工作区，切换地址后需要重新登录。", systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 520)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .background(Color.listBackground)
            .navigationTitle("Agent Workspace")
            .crossPlatformNavigationBarTitleDisplayModeInline()
            .navigationDestination(isPresented: $showRegister) {
                RegisterView(serverURL: serverUrl)
            }
        }
        .tint(.brandPrimary)
        .onAppear {
            if serverUrl.isEmpty { serverUrl = networkManager.baseUrl }
        }
    }

    private func openRegistration() {
        do {
            try networkManager.configureServer(serverUrl)
            serverUrl = networkManager.baseUrl
            errorMessage = nil
            showRegister = true
        } catch {
            errorMessage = error.localizedDescription
            focusedField = .server
        }
    }

    private func handleLogin() {
        guard !isLoading else { return }
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEmail.isEmpty, !password.isEmpty else {
            errorMessage = "请填写邮箱和密码。"
            focusedField = normalizedEmail.isEmpty ? .email : .password
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
                try await networkManager.login(email: normalizedEmail, password: password)
                password = ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview { LoginView() }
