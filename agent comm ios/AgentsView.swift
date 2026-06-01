import SwiftUI

struct AgentsView: View {
    @ObservedObject var networkManager = NetworkManager.shared
    @State private var agents: [Agent] = []
    @State private var isLoading = false
    @State private var showAddAgent = false
    @State private var errorMessage = ""
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.systemGroupedBackground
                    .edgesIgnoringSafeArea(.all)
                
                if isLoading && agents.isEmpty {
                    ProgressView("Loading Agents...")
                        .progressViewStyle(CircularProgressViewStyle(tint: .brandPrimary))
                } else if agents.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "cpu.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)
                        
                        Text("No agents registered yet")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
                        Button(action: { showAddAgent = true }) {
                            Text("Register/Bind Agent")
                                .bold()
                        }
                        .buttonStyle(PremiumButtonStyle(backgroundColor: .brandPrimary))
                        .padding(.horizontal, 40)
                    }
                } else {
                    List {
                        ForEach(agents) { agent in
                            NavigationLink(destination: AgentDetailView(agent: agent, onUpdate: {
                                Task { await loadAgents() }
                            })) {
                                AgentRow(agent: agent)
                            }
                        }
                    }
                    .crossPlatformListStyle()
                }
            }
            .navigationTitle("Agents")
            .crossPlatformToolbar(
                leading: AnyView(Button(action: {
                    Task { await loadAgents() }
                }) {
                    Image(systemName: "arrow.clockwise")
                }),
                trailing: AnyView(Button(action: {
                    showAddAgent = true
                }) {
                    Image(systemName: "plus")
                        .font(.title3)
                })
            )
            .sheet(isPresented: $showAddAgent) {
                AddAgentSheet(onSuccess: {
                    Task { await loadAgents() }
                })
            }
            .onAppear {
                Task {
                    await loadAgents()
                }
            }
        }
        .crossPlatformNavigationViewStyle()
    }
    
    private func loadAgents() async {
        DispatchQueue.main.async {
            self.isLoading = true
            self.errorMessage = ""
        }
        
        do {
            let loadedAgents = try await networkManager.fetchAgents()
            DispatchQueue.main.async {
                self.agents = loadedAgents
                self.isLoading = false
            }
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }
}

// MARK: - Agent Row Component
struct AgentRow: View {
    let agent: Agent
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.brandPrimary.opacity(0.1))
                    .frame(width: 44, height: 44)
                
                Image(systemName: "cpu")
                    .foregroundColor(.brandPrimary)
                    .font(.title3)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(agent.name)
                    .font(.headline)
                Text(agent.urn)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            if agent.platformRegistered {
                StatusBadge(text: "Registered", iconName: "cloud.fill", color: .statusSuccess)
            } else {
                StatusBadge(text: "Local Only", iconName: "house.fill", color: .secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Agent Detail View
struct AgentDetailView: View {
    let agent: Agent
    let onUpdate: () -> Void
    @Environment(\.presentationMode) var presentationMode
    @ObservedObject var networkManager = NetworkManager.shared
    @State private var isRegistering = false
    @State private var registerError = ""
    @State private var copiedText = ""
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header details Card
                VStack(spacing: 12) {
                    Image(systemName: "cpu.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.brandPrimary)
                        .padding(.top)
                    
                    Text(agent.name)
                        .font(.title)
                        .bold()
                    
                    if agent.platformRegistered {
                        StatusBadge(text: "Registered on Platform", iconName: "cloud.fill", color: .statusSuccess)
                    } else {
                        VStack(spacing: 8) {
                            StatusBadge(text: "Unregistered (Local)", iconName: "exclamationmark.triangle.fill", color: .statusWarning)
                            
                            Button(action: handleRegisterToPlatform) {
                                if isRegistering {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                } else {
                                    Text("Register to Platform")
                                        .font(.subheadline)
                                        .bold()
                                }
                            }
                            .buttonStyle(PremiumButtonStyle(backgroundColor: .brandPrimary, cornerRadius: 8, isDisabled: isRegistering))
                            .frame(width: 200)
                            .padding(.top, 4)
                        }
                    }
                    
                    if !registerError.isEmpty {
                        Text(registerError)
                            .font(.caption)
                            .foregroundColor(.statusDestructive)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.secondarySystemGroupedBackground)
                .cornerRadius(16)
                .padding(.horizontal)
                
                // Copy popup indicator
                if !copiedText.isEmpty {
                    Text("Copied \(copiedText)!")
                        .font(.caption)
                        .bold()
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.8))
                        .cornerRadius(20)
                        .transition(.scale.combined(with: .opacity))
                }
                
                // Details Card
                VStack(alignment: .leading, spacing: 16) {
                    DetailRow(title: "Agent URN", value: agent.urn, copyable: true, copiedName: "URN", onCopy: showCopyBanner)
                    
                    DetailRow(title: "Local URL", value: agent.localUrl ?? "Not Configured", copyable: false, copiedName: "", onCopy: showCopyBanner)
                    
                    DetailRow(title: "Public Key", value: agent.publicKey, copyable: true, copiedName: "Public Key", onCopy: showCopyBanner)
                    
                    if let privKey = agent.encryptedPrivateKey {
                        DetailRow(title: "Encrypted Private Key", value: privKey, copyable: true, copiedName: "Private Key", onCopy: showCopyBanner)
                    }
                    
                    if let salt = agent.keySalt {
                        DetailRow(title: "Key Salt", value: salt, copyable: false, copiedName: "", onCopy: showCopyBanner)
                    }
                }
                .padding()
                .background(Color.secondarySystemGroupedBackground)
                .cornerRadius(16)
                .padding(.horizontal)
                
                Spacer()
            }
        }
        .background(Color.systemGroupedBackground)
        .crossPlatformNavigationBarTitleDisplayModeInline()
        .navigationTitle("Agent Details")
    }
    
    private func showCopyBanner(name: String) {
        withAnimation {
            copiedText = name
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                copiedText = ""
            }
        }
    }
    
    private func handleRegisterToPlatform() {
        isRegistering = true
        registerError = ""
        
        Task {
            do {
                _ = try await networkManager.registerAgentToPlatform(agentId: agent.id)
                DispatchQueue.main.async {
                    self.isRegistering = false
                    self.onUpdate()
                    self.presentationMode.wrappedValue.dismiss()
                }
            } catch {
                DispatchQueue.main.async {
                    self.registerError = error.localizedDescription
                    self.isRegistering = false
                }
            }
        }
    }
}

// MARK: - Detail Row Helper
struct DetailRow: View {
    let title: String
    let value: String
    let copyable: Bool
    let copiedName: String
    let onCopy: (String) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .bold()
                .foregroundColor(.secondary)
            
            HStack {
                Text(value)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                
                Spacer()
                
                if copyable {
                    Button(action: {
                        Clipboard.copy(text: value)
                        onCopy(copiedName)
                    }) {
                        Image(systemName: "doc.on.doc.fill")
                            .foregroundColor(.brandPrimary)
                            .font(.subheadline)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Add Agent Sheet Component
struct AddAgentSheet: View {
    @Environment(\.presentationMode) var presentationMode
    @ObservedObject var networkManager = NetworkManager.shared
    @State private var mode = "create" // "create" or "bind"
    @State private var name = ""
    @State private var localUrl = ""
    @State private var password = ""
    @State private var urn = ""
    @State private var publicKey = ""
    @State private var isLoading = false
    @State private var errorMessage = ""
    
    let onSuccess: () -> Void
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Registration Mode")) {
                    Picker("Mode", selection: $mode) {
                        Text("Create New Keys").tag("create")
                        Text("Bind Existing URN").tag("bind")
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }
                
                Section(header: Text("Basic Details")) {
                    TextField("Agent Name (e.g. Writer Agent)", text: $name)
                    TextField("Local endpoint (e.g. http://localhost:8000)", text: $localUrl)
                        .crossPlatformAutocapitalization()
                        .disableAutocorrection(true)
                        .crossPlatformKeyboardType(.url)
                }
                
                if mode == "create" {
                    Section(header: Text("Key Generation Settings")) {
                        SecureField("Encryption Password", text: $password)
                    }
                } else {
                    Section(header: Text("Existing Identity Keys")) {
                        TextField("Agent URN (e.g. urn:agent:uuid)", text: $urn)
                            .crossPlatformAutocapitalization()
                            .disableAutocorrection(true)
                        
                        TextField("Public Key (Hex String)", text: $publicKey)
                            .crossPlatformAutocapitalization()
                            .disableAutocorrection(true)
                    }
                }
                
                if !errorMessage.isEmpty {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.statusDestructive)
                            .font(.caption)
                    }
                }
                
                Section {
                    Button(action: handleAddAgent) {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .padding(.trailing, 8)
                            }
                            Text(isLoading ? "Processing..." : (mode == "create" ? "Generate & Register" : "Bind Agent"))
                        }
                        .frame(maxWidth: .infinity)
                        .alignmentGuide(.leading) { _ in 0 }
                    }
                    .buttonStyle(PremiumButtonStyle(backgroundColor: mode == "create" ? .brandPrimary : .brandSecondary, isDisabled: isLoading))
                    .disabled(isLoading)
                }
            }
            .navigationTitle("Add Agent")
            .crossPlatformNavigationBarTitleDisplayModeInline()
            .crossPlatformToolbar(leading: AnyView(Button("Cancel") {
                presentationMode.wrappedValue.dismiss()
            }))
        }
    }
    
    private func handleAddAgent() {
        guard !name.isEmpty else {
            errorMessage = "Name is required"
            return
        }
        
        if mode == "create" {
            guard !password.isEmpty else {
                errorMessage = "Encryption password is required"
                return
            }
        } else {
            guard !urn.isEmpty else {
                errorMessage = "URN is required for binding"
                return
            }
        }
        
        isLoading = true
        errorMessage = ""
        
        Task {
            do {
                _ = try await networkManager.createAgent(
                    mode: mode,
                    name: name,
                    password: password.isEmpty ? nil : password,
                    urn: urn.isEmpty ? nil : urn,
                    publicKey: publicKey.isEmpty ? nil : publicKey,
                    localUrl: localUrl.isEmpty ? nil : localUrl
                )
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.onSuccess()
                    self.presentationMode.wrappedValue.dismiss()
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}

struct AgentsView_Previews: PreviewProvider {
    static var previews: some View {
        AgentsView()
    }
}
