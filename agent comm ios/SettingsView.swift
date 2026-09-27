import SwiftUI
import AgentWorkspaceKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var networkManager = NetworkManager.shared
    @State private var serverUrl = ""
    @State private var testingConnection = false
    @State private var signingOut = false
    @State private var testResult: String?
    @State private var testSuccess = false
    @State private var saveError: String?
    @State private var confirmServerChange = false
    @FocusState private var serverIsFocused: Bool
    @AccessibilityFocusState private var resultHasFocus: Bool

    private var hasServerChanges: Bool {
        (try? WorkspaceClient.validateServer(serverUrl).absoluteString) != networkManager.baseUrl
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("账户") {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(Color.brandPrimary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(networkManager.currentUser?.email ?? "尚未登录")
                                .font(.headline)
                                .textSelection(.enabled)
                            Text(networkManager.isAuthenticated ? "已连接到当前工作区" : "登录后查看工作区内容")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    if networkManager.isAuthenticated { NavigationLink("账户与安全") { AccountSecurityView() } }
                    if networkManager.isAuthenticated { NavigationLink("举报记录") { ContentReportsView() } }
                }

                Section {
                    WorkspaceField(title: "工作区地址") {
                        TextField("https://workspace.example.com", text: $serverUrl)
                            .accessibilityLabel("工作区地址")
                            .crossPlatformAutocapitalization()
                            .autocorrectionDisabled()
                            .crossPlatformKeyboardType(.url)
                            .textFieldStyle(.plain)
                            .padding(.vertical, 6)
                            .focused($serverIsFocused)
                            .submitLabel(.done)
                            .onSubmit { serverIsFocused = false }
                    }
                    Button(action: handleTestConnection) {
                        HStack(spacing: 8) {
                            if testingConnection { ProgressView().controlSize(.small) }
                            Label(testingConnection ? "正在检查…" : "测试连接", systemImage: "network")
                        }
                        .workspaceTapTarget()
                    }
                    .disabled(testingConnection || serverUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let testResult {
                        InlineNotice(message: testResult, style: testSuccess ? .success : .error)
                            .accessibilityFocused($resultHasFocus)
                    }
                    if let saveError {
                        InlineNotice(message: saveError, style: .error)
                            .accessibilityFocused($resultHasFocus)
                    }
                    Button(action: requestSaveServer) {
                        Text("保存工作区地址").workspaceTapTarget()
                    }
                        .disabled(!hasServerChanges || testingConnection || signingOut)
                } header: {
                    Text("连接设置")
                } footer: {
                    Text("测试连接只检查服务是否可用。保存不同的工作区地址会退出当前账户；你需要在新工作区重新登录。")
                }

                Section("使用说明") {
                    NavigationLink {
                        WorkspaceDataView()
                    } label: {
                        Label("数据与隐私", systemImage: "hand.raised").workspaceTapTarget()
                    }
                    Label {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("让设备连接到工作区")
                                .font(.subheadline.weight(.semibold))
                            Text("手机上的 localhost 指向手机自身。连接电脑上的服务时，使用电脑的局域网地址，并让两台设备处于同一网络。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "wifi")
                    }
                    .padding(.vertical, 4)
                    Label {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("本地智能体的访问权限")
                                .font(.subheadline.weight(.semibold))
                            Text("通过一次性连接链接或在 Agent 本机配对控制台身份。保存地址不会自动授予权限；好友、消息和协作确认等操作按本机授权范围开放。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "lock.shield")
                    }
                    .padding(.vertical, 4)
                }

                if networkManager.isAuthenticated {
                    Section {
                        Button(role: .destructive, action: handleLogout) {
                            HStack(spacing: 8) {
                                if signingOut { ProgressView().controlSize(.small) }
                                Label(signingOut ? "正在退出…" : "退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                            .workspaceTapTarget()
                        }
                        .disabled(signingOut || testingConnection)
                    } footer: {
                        Text("退出会清除此设备的登录状态，工作区中的数据会保留。")
                    }
                }
            }
            .formStyle(.grouped)
            .workspaceScrollDismissesKeyboard()
            .navigationTitle("设置")
            .crossPlatformNavigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.disabled(signingOut)
                }
            }
            .onAppear { serverUrl = networkManager.baseUrl }
            .onChange(of: serverUrl) { _, _ in
                testResult = nil
                saveError = nil
            }
            .onChange(of: testResult) { _, value in resultHasFocus = value != nil }
            .onChange(of: saveError) { _, value in resultHasFocus = value != nil }
            .confirmationDialog("切换工作区？", isPresented: $confirmServerChange, titleVisibility: .visible) {
                Button("切换并退出当前账户", action: saveServer)
                Button("取消", role: .cancel) { }
            } message: {
                Text("保存这个地址会退出当前账户。你需要在新工作区重新登录；原工作区的数据会保留。")
            }
        }
        .tint(.brandPrimary)
        .frame(minWidth: 320, idealWidth: 540, idealHeight: 700)
    }

    private func requestSaveServer() {
        do {
            _ = try WorkspaceClient.validateServer(serverUrl)
            serverIsFocused = false
            saveError = nil
            if networkManager.isAuthenticated { confirmServerChange = true }
            else { saveServer() }
        } catch {
            saveError = error.localizedDescription
            serverIsFocused = true
        }
    }

    private func saveServer() {
        do {
            try networkManager.configureServer(serverUrl)
            serverUrl = networkManager.baseUrl
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func handleTestConnection() {
        guard !testingConnection, !signingOut else { return }
        let target = serverUrl
        serverIsFocused = false
        testingConnection = true
        testResult = nil
        Task {
            defer { testingConnection = false }
            do {
                try await networkManager.testConnection(server: target)
                guard serverUrl == target else { return }
                testSuccess = true
                testResult = "工作区连接正常，可以使用这个地址登录。"
            } catch {
                guard serverUrl == target else { return }
                testSuccess = false
                testResult = error.localizedDescription
            }
        }
    }

    private func handleLogout() {
        guard !signingOut else { return }
        signingOut = true
        Task {
            // The client clears local credentials even when the server is unreachable.
            try? await networkManager.logout()
            signingOut = false
            dismiss()
        }
    }
}

#Preview { SettingsView() }
