import SwiftUI

struct ServicesView: View {
    @ObservedObject var networkManager = NetworkManager.shared
    @State private var agents: [Agent] = []
    @State private var contacts: [Contact] = []
    @State private var discoveredServices: [ServiceDescription] = []
    
    @State private var selectedAgentIndex = 0
    @State private var selectedContactIndex = 0
    @State private var selectedService: ServiceDescription? = nil
    
    @State private var args: [String: String] = [:] // Dynamic string arguments inputs
    @State private var isLoading = false
    @State private var isInvoking = false
    @State private var message = ""
    @State private var isError = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Config Section
                VStack(spacing: 16) {
                    Text("INVOCATION PATHWAY")
                        .font(.caption)
                        .bold()
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("FROM SENDER AGENT")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                        
                        if agents.isEmpty {
                            Text("No Agents Available")
                                .foregroundColor(.statusDestructive)
                        } else {
                            Picker("Sender Agent", selection: $selectedAgentIndex) {
                                ForEach(0..<agents.count, id: \.self) { idx in
                                    Text(agents[idx].name).tag(idx)
                                }
                            }
                            .pickerStyle(MenuPickerStyle())
                        }
                    }
                    
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("TO DESTINATION AGENT / CONTACT")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                        
                        if contacts.isEmpty {
                            Text("No Contacts Available")
                                .foregroundColor(.statusDestructive)
                        } else {
                            Picker("Contact", selection: $selectedContactIndex) {
                                ForEach(0..<contacts.count, id: \.self) { idx in
                                    Text(contacts[idx].displayName).tag(idx)
                                }
                            }
                            .pickerStyle(MenuPickerStyle())
                            .onChange(of: selectedContactIndex) { _ in
                                selectedService = nil
                                discoveredServices = []
                            }
                        }
                    }
                    
                    Button(action: handleDiscoverServices) {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .padding(.trailing, 8)
                            }
                            Image(systemName: "magnifyingglass")
                            Text("Discover Services")
                        }
                    }
                    .buttonStyle(PremiumButtonStyle(backgroundColor: .brandPrimary, cornerRadius: 8, isDisabled: isLoading || contacts.isEmpty))
                    .disabled(isLoading || contacts.isEmpty)
                }
                .padding()
                .background(Color.secondarySystemGroupedBackground)
                .cornerRadius(16)
                .padding(.horizontal)
                
                // Status Messages
                if !message.isEmpty {
                    HStack {
                        Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundColor(isError ? .statusDestructive : .statusSuccess)
                        Text(message)
                            .font(.subheadline)
                            .foregroundColor(.white)
                        Spacer()
                    }
                    .padding()
                    .background((isError ? Color.statusDestructive : Color.statusSuccess).opacity(0.15))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke((isError ? Color.statusDestructive : Color.statusSuccess).opacity(0.3), lineWidth: 1)
                    )
                    .padding(.horizontal)
                }
                
                // Discovered Services List
                if !discoveredServices.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("AVAILABLE SERVICES")
                            .font(.caption)
                            .bold()
                            .foregroundColor(.secondary)
                            .padding(.leading)
                        
                        ForEach(discoveredServices) { service in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(service.name)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    if service.requiresHitl {
                                        StatusBadge(text: "Requires HITL", iconName: "shield.fill", color: .statusWarning)
                                    }
                                }
                                
                                Text(service.description)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                
                                if selectedService?.name == service.name {
                                    // Render arguments forms
                                    VStack(alignment: .leading, spacing: 12) {
                                        Divider()
                                        Text("INPUT ARGUMENTS")
                                            .font(.caption2)
                                            .bold()
                                            .foregroundColor(.brandPrimary)
                                        
                                        if let schema = service.inputSchema, let properties = schema.properties {
                                            ForEach(properties.keys.sorted(), id: \.self) { key in
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(key.uppercased())
                                                        .font(.system(size: 9, weight: .semibold))
                                                        .foregroundColor(.secondary)
                                                    
                                                    TextField(properties[key]?.description ?? "Value", text: Binding(
                                                        get: { self.args[key] ?? "" },
                                                        set: { self.args[key] = $0 }
                                                    ))
                                                    .crossPlatformAutocapitalization()
                                                    .disableAutocorrection(true)
                                                    .padding(10)
                                                    .background(Color.secondarySystemBackground)
                                                    .cornerRadius(8)
                                                }
                                            }
                                        } else {
                                            Text("No input arguments needed.")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        
                                        Button(action: handleInvokeService) {
                                            HStack {
                                                if isInvoking {
                                                    ProgressView()
                                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                                        .padding(.trailing, 8)
                                                }
                                                Image(systemName: "play.fill")
                                                Text("Invoke Service Call")
                                            }
                                        }
                                        .buttonStyle(PremiumButtonStyle(backgroundColor: .statusSuccess, cornerRadius: 8, isDisabled: isInvoking))
                                        .disabled(isInvoking)
                                        .padding(.top, 4)
                                    }
                                    .transition(.opacity)
                                }
                            }
                            .padding()
                            .background(Color.secondarySystemGroupedBackground)
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(selectedService?.name == service.name ? Color.brandPrimary : Color.clear, lineWidth: 1.5)
                            )
                            .shadow(color: Color.black.opacity(0.02), radius: 3, x: 0, y: 1)
                            .onTapGesture {
                                withAnimation {
                                    if selectedService?.name == service.name {
                                        selectedService = nil
                                    } else {
                                        selectedService = service
                                        args = [:] // Clear args
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.vertical)
        }
        .background(Color.systemGroupedBackground)
        .navigationTitle("Services Discovery")
        .crossPlatformNavigationBarTitleDisplayModeInline()
        .onAppear {
            Task {
                await loadConfigurations()
            }
        }
    }
    
    private func loadConfigurations() async {
        do {
            let loadedAgents = try await networkManager.fetchAgents()
            let loadedContacts = try await networkManager.fetchContacts()
            DispatchQueue.main.async {
                self.agents = loadedAgents
                self.contacts = loadedContacts
            }
        } catch {
            print("Failed to load configs for services: \(error)")
        }
    }
    
    private func handleDiscoverServices() {
        guard !contacts.isEmpty, selectedContactIndex < contacts.count else { return }
        let targetUrn = contacts[selectedContactIndex].contactUrn
        
        isLoading = true
        message = ""
        discoveredServices = []
        
        Task {
            do {
                let services = try await networkManager.fetchServices(targetUrn: targetUrn)
                DispatchQueue.main.async {
                    self.discoveredServices = services
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.isError = true
                    self.message = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
    
    private func handleInvokeService() {
        guard let service = selectedService else { return }
        guard !agents.isEmpty, selectedAgentIndex < agents.count else { return }
        let agentId = agents[selectedAgentIndex].id
        guard !contacts.isEmpty, selectedContactIndex < contacts.count else { return }
        let targetUrn = contacts[selectedContactIndex].contactUrn
        
        isInvoking = true
        message = ""
        
        // Map arguments to dictionary
        var dictArgs: [String: Any] = [:]
        for (key, val) in args {
            dictArgs[key] = val
        }
        
        Task {
            do {
                _ = try await networkManager.invokeService(
                    agentId: agentId,
                    targetUrn: targetUrn,
                    serviceName: service.name,
                    args: dictArgs
                )
                
                DispatchQueue.main.async {
                    self.isError = false
                    self.message = "Service call requested! HITL approval required."
                    self.isInvoking = false
                    self.selectedService = nil // Close sheet
                }
            } catch {
                DispatchQueue.main.async {
                    self.isError = true
                    self.message = error.localizedDescription
                    self.isInvoking = false
                }
            }
        }
    }
}

struct ServicesView_Previews: PreviewProvider {
    static var previews: some View {
        ServicesView()
    }
}
