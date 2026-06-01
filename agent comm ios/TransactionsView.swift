import SwiftUI

struct TransactionsView: View {
    @ObservedObject var networkManager = NetworkManager.shared
    @State private var agents: [Agent] = []
    @State private var contacts: [Contact] = []
    @State private var transactions: [Transaction] = []
    
    @State private var selectedAgentIndex = 0
    @State private var recipientUrn = ""
    @State private var selectedContactIndex = -1 // -1 means custom input
    @State private var amount = ""
    @State private var memo = ""
    
    @State private var isLoading = false
    @State private var isSubmitting = false
    @State private var message = ""
    @State private var isError = false
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.systemGroupedBackground
                    .edgesIgnoringSafeArea(.all)
                
                ScrollView {
                    VStack(spacing: 20) {
                        // Transfer Tokens Card
                        VStack(spacing: 16) {
                            Text("INITIATE TOKEN TRANSFER")
                                .font(.caption)
                                .bold()
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            
                            // Sender Agent Picker
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
                            
                            // Recipient picker helper / Text Field
                            VStack(alignment: .leading, spacing: 6) {
                                Text("RECIPIENT CONTACT OR URN")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.secondary)
                                
                                HStack {
                                    TextField("urn:agent:...", text: $recipientUrn)
                                        .crossPlatformAutocapitalization()
                                        .disableAutocorrection(true)
                                        .padding(10)
                                        .background(Color.secondarySystemBackground)
                                        .cornerRadius(8)
                                        .onChange(of: recipientUrn) { _ in
                                            // Reset contact picker if manual input changed
                                            selectedContactIndex = -1
                                        }
                                    
                                    if !contacts.isEmpty {
                                        Picker("Contacts List", selection: $selectedContactIndex) {
                                            Text("Custom URN").tag(-1)
                                            ForEach(0..<contacts.count, id: \.self) { idx in
                                                Text(contacts[idx].contactUrn).tag(idx)
                                            }
                                        }
                                        .pickerStyle(MenuPickerStyle())
                                        .onChange(of: selectedContactIndex) { idx in
                                            if idx != -1 {
                                                recipientUrn = contacts[idx].contactUrn
                                            }
                                        }
                                    }
                                }
                            }
                            
                            // Amount & Memo Row
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("AMOUNT")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.secondary)
                                    
                                    TextField("0.0", text: $amount)
                                        .crossPlatformKeyboardType(.decimal)
                                        .padding(10)
                                        .background(Color.secondarySystemBackground)
                                        .cornerRadius(8)
                                }
                                .frame(width: 100)
                                
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("MEMO")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.secondary)
                                    
                                    TextField("Payment info", text: $memo)
                                        .padding(10)
                                        .background(Color.secondarySystemBackground)
                                        .cornerRadius(8)
                                }
                            }
                            
                            // Submit Button
                            Button(action: handleTransfer) {
                                HStack {
                                    if isSubmitting {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                            .padding(.trailing, 8)
                                    }
                                    Image(systemName: "paperplane.fill")
                                    Text("Submit Transfer")
                                }
                            }
                            .buttonStyle(PremiumButtonStyle(backgroundColor: .statusSuccess, cornerRadius: 8, isDisabled: isSubmitting || agents.isEmpty))
                            .disabled(isSubmitting || agents.isEmpty)
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
                        
                        // Transaction History Ledger
                        VStack(alignment: .leading, spacing: 12) {
                            Text("LEDGER HISTORY")
                                .font(.caption)
                                .bold()
                                .foregroundColor(.secondary)
                                .padding(.leading)
                            
                            if isLoading && transactions.isEmpty {
                                HStack {
                                    Spacer()
                                    ProgressView()
                                    Spacer()
                                }
                                .padding()
                            } else if transactions.isEmpty {
                                VStack(spacing: 8) {
                                    Image(systemName: "list.bullet.rectangle.portrait")
                                        .font(.title)
                                        .foregroundColor(.secondary)
                                    Text("No transactions found")
                                        .foregroundColor(.secondary)
                                        .font(.subheadline)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 30)
                                .background(Color.secondarySystemGroupedBackground)
                                .cornerRadius(12)
                                .padding(.horizontal)
                            } else {
                                ForEach(transactions) { tx in
                                    TransactionRow(tx: tx)
                                        .padding(.horizontal)
                                }
                            }
                        }
                    }
                }
                .refreshable {
                    await loadTransactions()
                }
            }
            .navigationTitle("Transactions")
            .onAppear {
                Task {
                    await loadConfigurations()
                    await loadTransactions()
                }
            }
        }
        .crossPlatformNavigationViewStyle()
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
            print("Failed to load configs for transactions: \(error)")
        }
    }
    
    private func loadTransactions() async {
        DispatchQueue.main.async {
            self.isLoading = true
        }
        
        do {
            let loadedTx = try await networkManager.fetchTransactions()
            DispatchQueue.main.async {
                self.transactions = loadedTx
                self.isLoading = false
            }
        } catch {
            print("Failed to fetch transactions: \(error)")
            DispatchQueue.main.async {
                self.isLoading = false
            }
        }
    }
    
    private func handleTransfer() {
        guard !agents.isEmpty, selectedAgentIndex < agents.count else { return }
        let agentId = agents[selectedAgentIndex].id
        let recipient = recipientUrn.trimmingCharacters(in: .whitespacesAndNewlines)
        let txAmount = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !recipient.isEmpty else {
            isError = true
            message = "Recipient URN is required"
            return
        }
        
        guard !txAmount.isEmpty, Double(txAmount) != nil else {
            isError = true
            message = "Valid numeric amount is required"
            return
        }
        
        isSubmitting = true
        message = ""
        
        Task {
            do {
                _ = try await networkManager.createTransaction(
                    agentId: agentId,
                    recipientUrn: recipient,
                    amount: txAmount,
                    memo: memo
                )
                
                await loadTransactions()
                
                DispatchQueue.main.async {
                    self.isError = false
                    self.message = "Transaction initiated! HITL approval requested."
                    self.amount = ""
                    self.memo = ""
                    self.recipientUrn = ""
                    self.selectedContactIndex = -1
                    self.isSubmitting = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.isError = true
                    self.message = error.localizedDescription
                    self.isSubmitting = false
                }
            }
        }
    }
}

// MARK: - Transaction Row Helper
struct TransactionRow: View {
    let tx: Transaction
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "creditcard")
                        .foregroundColor(.brandPrimary)
                    Text("\(tx.amount) \(tx.currency)")
                        .font(.headline)
                        .bold()
                }
                
                Spacer()
                
                getStatusBadge()
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("FROM:")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                    Text(tx.fromUrn)
                        .font(.caption2)
                        .lineLimit(1)
                }
                
                HStack {
                    Text("TO:")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                    Text(tx.toUrn)
                        .font(.caption2)
                        .lineLimit(1)
                }
                
                if let hash = tx.txHash, !hash.isEmpty {
                    HStack {
                        Text("HASH:")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.secondary)
                        Text(hash)
                            .font(.system(size: 8, design: .monospaced))
                            .lineLimit(1)
                    }
                }
            }
            
            HStack {
                Spacer()
                Text(formatDate(tx.createdAt))
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color.secondarySystemGroupedBackground)
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.02), radius: 3, x: 0, y: 1)
    }
    
    private func getStatusBadge() -> some View {
        switch tx.status {
        case "pending":
            return StatusBadge(text: "Pending", iconName: "clock.fill", color: .statusWarning)
        case "confirmed":
            return StatusBadge(text: "Confirmed", iconName: "checkmark.circle.fill", color: .statusSuccess)
        default:
            return StatusBadge(text: "Failed", iconName: "xmark.circle.fill", color: .statusDestructive)
        }
    }
    
    private func formatDate(_ isoDate: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        let altFormatter = ISO8601DateFormatter()
        altFormatter.formatOptions = [.withInternetDateTime]
        
        guard let date = formatter.date(from: isoDate) ?? altFormatter.date(from: isoDate) else {
            return isoDate
        }
        
        let displayFormatter = DateFormatter()
        displayFormatter.dateStyle = .short
        displayFormatter.timeStyle = .short
        return displayFormatter.string(from: date)
    }
}

struct TransactionsView_Previews: PreviewProvider {
    static var previews: some View {
        TransactionsView()
    }
}
