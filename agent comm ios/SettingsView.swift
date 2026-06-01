import SwiftUI

struct SettingsView: View {
    @Environment(\.presentationMode) var presentationMode
    @ObservedObject var networkManager = NetworkManager.shared
    @State private var serverUrl = ""
    @State private var testingConnection = false
    @State private var testResult = ""
    @State private var testSuccess = false
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Account Profile")) {
                    HStack {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.largeTitle)
                            .foregroundColor(.brandPrimary)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(networkManager.currentUser?.email ?? "Not Logged In")
                                .font(.headline)
                            Text("User ID: \(networkManager.currentUser?.id ?? "None")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                Section(header: Text("Server Setup"), footer: Text("Set your Next.js application server base URL. Make sure it is reachable from this device/simulator.")) {
                    TextField("Server URL (e.g. http://localhost:3000)", text: $serverUrl)
                        .crossPlatformAutocapitalization()
                        .disableAutocorrection(true)
                        .crossPlatformKeyboardType(.url)
                    
                    Button(action: handleTestConnection) {
                        HStack {
                            if testingConnection {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Text("Test Connection")
                                .bold()
                        }
                    }
                    .disabled(testingConnection || serverUrl.isEmpty)
                    
                    if !testResult.isEmpty {
                        HStack {
                            Image(systemName: testSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(testSuccess ? .statusSuccess : .statusDestructive)
                            Text(testResult)
                                .font(.caption)
                                .foregroundColor(.primary)
                        }
                    }
                }
                
                Section(header: Text("Diagnostics")) {
                    HStack {
                        Text("Session Authenticated")
                        Spacer()
                        Text(networkManager.isAuthenticated ? "YES" : "NO")
                            .bold()
                            .foregroundColor(networkManager.isAuthenticated ? .statusSuccess : .statusDestructive)
                    }
                    
                    HStack {
                        Text("Cookies Active")
                        Spacer()
                        Text("\(HTTPCookieStorage.shared.cookies(for: URL(string: networkManager.baseUrl)!)?.count ?? 0)")
                            .bold()
                            .foregroundColor(.secondary)
                    }
                }
                
                Section {
                    Button(action: handleLogout) {
                        HStack {
                            Spacer()
                            Image(systemName: "power")
                            Text("Sign Out")
                                .bold()
                            Spacer()
                        }
                    }
                    .foregroundColor(.white)
                    .listRowBackground(Color.statusDestructive)
                }
            }
            .navigationTitle("Settings")
            .crossPlatformNavigationBarTitleDisplayModeInline()
            .crossPlatformToolbar(trailing: AnyView(Button("Done") {
                // Save base URL changes
                if !serverUrl.isEmpty && serverUrl != networkManager.baseUrl {
                    networkManager.baseUrl = serverUrl
                }
                presentationMode.wrappedValue.dismiss()
            }))
            .onAppear {
                serverUrl = networkManager.baseUrl
                testResult = ""
            }
        }
    }
    
    private func handleTestConnection() {
        testingConnection = true
        testResult = ""
        
        let targetUrl = serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: targetUrl + "/api/auth/session") else {
            testSuccess = false
            testResult = "Invalid URL layout"
            testingConnection = false
            return
        }
        
        Task {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 5.0
                
                let (_, response) = try await URLSession.shared.data(for: request)
                
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    DispatchQueue.main.async {
                        self.testSuccess = true
                        self.testResult = "Successfully reached server API!"
                        self.testingConnection = false
                    }
                } else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    DispatchQueue.main.async {
                        self.testSuccess = false
                        self.testResult = "Server replied with code \(code)"
                        self.testingConnection = false
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.testSuccess = false
                    self.testResult = "Failed: \(error.localizedDescription)"
                    self.testingConnection = false
                }
            }
        }
    }
    
    private func handleLogout() {
        Task {
            do {
                try await networkManager.logout()
                DispatchQueue.main.async {
                    self.presentationMode.wrappedValue.dismiss()
                }
            } catch {
                print("Logout error: \(error)")
            }
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
