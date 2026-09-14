import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var networkManager = NetworkManager.shared
    @State private var serverUrl = ""
    @State private var testingConnection = false
    @State private var signingOut = false
    @State private var testResult: String?
    @State private var testSuccess = false
    @State private var saveError: String?

    private var hasServerChanges: Bool {
        serverUrl.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")) != networkManager.baseUrl
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
                }

                Section {
                    WorkspaceField(title: "工作区地址") {
                        TextField("https://workspace.example.com", text: $serverUrl)
                            .crossPlatformAutocapitalization()
                            .autocorrectionDisabled()
                            .crossPlatformKeyboardType(.url)
                            .textFieldStyle(.plain)
                            .padding(.vertical, 6)
                    }
                    Button(action: handleTestConnection) {
                        HStack(spacing: 8) {
                            if testingConnection { ProgressView().controlSize(.small) }
                            Label(testingConnection ? "正在检查…" : "测试连接", systemImage: "network")
                        }
                        .frame(minHeight: 32)
                    }
                    .disabled(testingConnection || serverUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let testResult {
                        InlineNotice(message: testResult, style: testSuccess ? .success : .error)
                    }
                    if let saveError {
                        InlineNotice(message: saveError, style: .error)
                    }
                    Button("保存工作区地址", action: saveServer)
                        .frame(minHeight: 32)
                        .disabled(!hasServerChanges || testingConnection || signingOut)
                } header: {
                    Text("连接设置")
                } footer: {
                    Text("测试连接只检查服务是否可用。保存不同的工作区地址会退出当前账户；你需要在新工作区重新登录。")
                }

                Section("使用说明") {
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
                            Text("在 Agent 本机配对控制台身份；保存连接不会自动授予权限。联系人、对话和协作数据按本机授权范围同步。需要确认的操作请回原生渠道回应。")
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
                            .frame(minHeight: 32)
                        }
                        .disabled(signingOut || testingConnection)
                    } footer: {
                        Text("退出会清除此设备的登录状态，工作区中的数据会保留。")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("设置")
            .crossPlatformNavigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear { serverUrl = networkManager.baseUrl }
            .onChange(of: serverUrl) { _, _ in
                testResult = nil
                saveError = nil
            }
        }
        .tint(.brandPrimary)
        .frame(minWidth: 320, idealWidth: 540, idealHeight: 700)
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
        let target = serverUrl
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
