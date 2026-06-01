import SwiftUI
import Combine

struct MessagesView: View {
    @ObservedObject var networkManager = NetworkManager.shared
    @State private var agents: [Agent] = []
    @State private var contacts: [Contact] = []
    @State private var messages: [Message] = []
    
    @State private var selectedAgentIndex = 0
    @State private var selectedContactIndex = 0
    @State private var typeText = ""
    @State private var isConsoleMode = false
    @State private var isLoading = false
    @State private var isSending = false
    @State private var pollingTimer: AnyCancellable?
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Sender / Target Configuration Card
                VStack(spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("SENDER AGENT")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.secondary)
                            
                            if agents.isEmpty {
                                Text("No Agents Available")
                                    .font(.subheadline)
                                    .foregroundColor(.red)
                            } else {
                                Picker("Sender Agent", selection: $selectedAgentIndex) {
                                    ForEach(0..<agents.count, id: \.self) { idx in
                                        Text(agents[idx].name).tag(idx)
                                    }
                                }
                                .pickerStyle(MenuPickerStyle())
                                .labelsHidden()
                                .onChange(of: selectedAgentIndex) { _ in
                                    Task { await loadMessages() }
                                }
                            }
                        }
                        
                        Spacer()
                        
                        Divider().frame(height: 30)
                        
                        Spacer()
                        
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("CHAT RECIPIENT")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.secondary)
                            
                            if isConsoleMode {
                                Button(action: {
                                    isConsoleMode = false
                                    Task { await loadMessages() }
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "terminal.fill")
                                        Text("Console Mode")
                                    }
                                    .font(.subheadline)
                                    .bold()
                                    .foregroundColor(.brandSecondary)
                                }
                            } else if contacts.isEmpty {
                                Button(action: {
                                    if !agents.isEmpty {
                                        isConsoleMode = true
                                        Task { await loadMessages() }
                                    }
                                }) {
                                    Text("Switch to Console")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            } else {
                                Picker("Contact", selection: $selectedContactIndex) {
                                    ForEach(0..<contacts.count, id: \.self) { idx in
                                        Text(contacts[idx].displayName).tag(idx)
                                    }
                                }
                                .pickerStyle(MenuPickerStyle())
                                .labelsHidden()
                                .onChange(of: selectedContactIndex) { _ in
                                    Task { await loadMessages() }
                                }
                            }
                        }
                    }
                    
                    // Mode Toggle Action
                    if !agents.isEmpty && !contacts.isEmpty {
                        Divider()
                        
                        HStack {
                            Toggle(isOn: $isConsoleMode) {
                                Label(isConsoleMode ? "Owner Console Command (E2E)" : "Agent Collaboration", systemImage: isConsoleMode ? "terminal" : "bubble.left.and.bubble.right")
                                    .font(.caption)
                                    .bold()
                                    .foregroundColor(isConsoleMode ? .brandSecondary : .brandPrimary)
                            }
                            .onChange(of: isConsoleMode) { _ in
                                Task { await loadMessages() }
                            }
                        }
                    }
                }
                .padding()
                .background(Color.secondarySystemGroupedBackground)
                .cornerRadius(12)
                .shadow(color: Color.black.opacity(0.04), radius: 5, x: 0, y: 2)
                .padding()
                
                // Message List Chat Thread
                ZStack {
                    Color.systemGroupedBackground
                        .edgesIgnoringSafeArea(.all)
                    
                    if isLoading && messages.isEmpty {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .brandPrimary))
                    } else if messages.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)
                            Text("No messages in this thread")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Text(isConsoleMode ? "Send a direct command to control this agent." : "Start chatting to collaborate with other agents.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }
                    } else {
                        ScrollViewReader { scrollView in
                            ScrollView {
                                LazyVStack(spacing: 12) {
                                    ForEach(messages) { message in
                                        MessageBubbleRow(message: message, currentAgentUrn: currentAgentUrn)
                                    }
                                }
                                .padding()
                            }
                            .onAppear {
                                if let last = messages.last {
                                    scrollView.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                            .onChange(of: messages.count) { _ in
                                if let last = messages.last {
                                    withAnimation {
                                        scrollView.scrollTo(last.id, anchor: .bottom)
                                    }
                                }
                            }
                        }
                    }
                }
                
                // Typing Input Bar
                HStack(spacing: 12) {
                    TextField(isConsoleMode ? "Enter owner console command..." : "Type message for agent...", text: $typeText)
                        .padding(12)
                        .background(Color.secondarySystemBackground)
                        .cornerRadius(20)
                        .foregroundColor(.primary)
                        .font(.body)
                        .crossPlatformAutocapitalization()
                        .disableAutocorrection(true)
                    
                    Button(action: handleSendMessage) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                            .padding(10)
                            .background(Color.brandPrimary)
                            .clipShape(Circle())
                    }
                    .disabled(typeText.trimmingCharacters(in: .whitespaces).isEmpty || isSending)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.secondarySystemGroupedBackground)
            }
            .navigationTitle("Message Center")
            .onAppear {
                startPolling()
            }
            .onDisappear {
                stopPolling()
            }
        }
        .crossPlatformNavigationViewStyle()
    }
    
    // MARK: - Current URNs
    private var currentAgentUrn: String {
        guard !agents.isEmpty, selectedAgentIndex < agents.count else { return "" }
        return agents[selectedAgentIndex].urn
    }
    
    private var currentRecipientUrn: String {
        if isConsoleMode {
            return currentAgentUrn // Console mode messages the agent itself
        }
        
        guard !contacts.isEmpty, selectedContactIndex < contacts.count else { return "" }
        return contacts[selectedContactIndex].contactUrn
    }
    
    // MARK: - Data Fetch & Polling
    private func startPolling() {
        // Fetch once
        Task {
            await loadInitialConfiguration()
        }
        
        // Setup timer for every 3 seconds
        pollingTimer = Timer.publish(every: 3.0, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                Task {
                    await loadMessages(silent: true)
                }
            }
    }
    
    private func stopPolling() {
        pollingTimer?.cancel()
        pollingTimer = nil
    }
    
    private func loadInitialConfiguration() async {
        DispatchQueue.main.async {
            self.isLoading = true
        }
        
        do {
            let loadedAgents = try await networkManager.fetchAgents()
            let loadedContacts = try await networkManager.fetchContacts()
            
            DispatchQueue.main.async {
                self.agents = loadedAgents
                self.contacts = loadedContacts
                self.isLoading = false
                
                // Trigger messages fetch
                Task { await loadMessages() }
            }
        } catch {
            print("Failed to load initial configurations for messages: \(error)")
            DispatchQueue.main.async {
                self.isLoading = false
            }
        }
    }
    
    private func loadMessages(silent: Bool = false) async {
        guard !agents.isEmpty, selectedAgentIndex < agents.count else { return }
        
        let agentId = agents[selectedAgentIndex].id
        let recipient = currentRecipientUrn
        
        if recipient.isEmpty {
            DispatchQueue.main.async {
                self.messages = []
            }
            return
        }
        
        if !silent {
            DispatchQueue.main.async {
                self.isLoading = true
            }
        }
        
        do {
            let loadedMessages = try await networkManager.fetchMessages(agentId: agentId, contactUrn: recipient)
            DispatchQueue.main.async {
                self.messages = loadedMessages
                self.isLoading = false
            }
        } catch {
            print("Failed to fetch messages: \(error)")
            DispatchQueue.main.async {
                self.isLoading = false
            }
        }
    }
    
    private func handleSendMessage() {
        guard !agents.isEmpty, selectedAgentIndex < agents.count else { return }
        let agentId = agents[selectedAgentIndex].id
        let recipient = currentRecipientUrn
        let content = typeText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !content.isEmpty, !recipient.isEmpty else { return }
        
        isSending = true
        typeText = ""
        
        Task {
            do {
                _ = try await networkManager.sendMessage(agentId: agentId, recipientUrn: recipient, content: content)
                await loadMessages(silent: true)
                DispatchQueue.main.async {
                    self.isSending = false
                }
            } catch {
                print("Failed to send message: \(error)")
                DispatchQueue.main.async {
                    self.isSending = false
                }
            }
        }
    }
}

// MARK: - Message Bubble Component
struct MessageBubbleRow: View {
    let message: Message
    let currentAgentUrn: String
    
    var body: some View {
        HStack {
            if isOutgoing {
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text(message.content)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.brandPrimary)
                        .foregroundColor(.white)
                        .cornerRadius(18)
                    
                    Text(formatTime(message.createdAt))
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                        .padding(.trailing, 4)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.content)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.secondarySystemGroupedBackground)
                        .foregroundColor(.primary)
                        .cornerRadius(18)
                        .shadow(color: Color.black.opacity(0.02), radius: 2, x: 0, y: 1)
                    
                    Text(formatTime(message.createdAt))
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                        .padding(.leading, 4)
                }
                
                Spacer()
            }
        }
        .id(message.id)
    }
    
    private var isOutgoing: Bool {
        // If message has `isIncoming = false`, it is outgoing from our perspective.
        // Also if sender matches our agent and recipient matches target, it is outgoing.
        return !message.isIncoming
    }
    
    private func formatTime(_ isoDate: String) -> String {
        // Simple iso string formatter
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        let altFormatter = ISO8601DateFormatter()
        altFormatter.formatOptions = [.withInternetDateTime]
        
        guard let date = formatter.date(from: isoDate) ?? altFormatter.date(from: isoDate) else {
            return ""
        }
        
        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        return timeFormatter.string(from: date)
    }
}

struct MessagesView_Previews: PreviewProvider {
    static var previews: some View {
        MessagesView()
    }
}
