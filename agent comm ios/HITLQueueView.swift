import SwiftUI
import Combine

struct HITLQueueView: View {
    @ObservedObject var networkManager = NetworkManager.shared
    @State private var requests: [HITLRequest] = []
    @State private var selectedFilter = 0 // 0 = Pending, 1 = History
    @State private var isLoading = false
    @State private var errorMessage = ""
    @State private var pollingTimer: AnyCancellable?
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.systemGroupedBackground
                    .edgesIgnoringSafeArea(.all)
                
                VStack(spacing: 0) {
                    // Filter Tab Bar Picker
                    Picker("Filter", selection: $selectedFilter) {
                        Text("Pending").tag(0)
                        Text("History").tag(1)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .padding()
                    .background(Color.secondarySystemGroupedBackground)
                    
                    if isLoading && filteredRequests.isEmpty {
                        Spacer()
                        ProgressView("Loading Requests...")
                            .progressViewStyle(CircularProgressViewStyle(tint: .brandPrimary))
                        Spacer()
                    } else if filteredRequests.isEmpty {
                        Spacer()
                        VStack(spacing: 16) {
                            Image(systemName: "shield.slash.fill")
                                .font(.system(size: 60))
                                .foregroundColor(.secondary)
                            Text(selectedFilter == 0 ? "No pending approvals" : "No request history")
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    } else {
                        List {
                            ForEach(filteredRequests) { request in
                                HITLRequestCard(request: request, onResolve: { action in
                                    resolveRequest(id: request.id, action: action)
                                })
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            }
                        }
                        .listStyle(PlainListStyle())
                    }
                }
            }
            .navigationTitle("HITL Approvals")
            .crossPlatformToolbar(leading: AnyView(Button(action: {
                Task { await loadRequests() }
            }) {
                Image(systemName: "arrow.clockwise")
            }))
            .onAppear {
                startPolling()
            }
            .onDisappear {
                stopPolling()
            }
        }
        .crossPlatformNavigationViewStyle()
    }
    
    // MARK: - Filter Helper
    private var filteredRequests: [HITLRequest] {
        if selectedFilter == 0 {
            return requests.filter { $0.status == "pending" }
        } else {
            return requests.filter { $0.status != "pending" }
        }
    }
    
    // MARK: - Polling
    private func startPolling() {
        Task { await loadRequests() }
        pollingTimer = Timer.publish(every: 10.0, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                Task { await loadRequests(silent: true) }
            }
    }
    
    private func stopPolling() {
        pollingTimer?.cancel()
        pollingTimer = nil
    }
    
    private func loadRequests(silent: Bool = false) async {
        if !silent {
            DispatchQueue.main.async {
                self.isLoading = true
                self.errorMessage = ""
            }
        }
        
        do {
            let loaded = try await networkManager.fetchHITLRequests()
            DispatchQueue.main.async {
                self.requests = loaded
                self.isLoading = false
            }
        } catch {
            print("Failed to fetch HITL requests: \(error)")
            DispatchQueue.main.async {
                self.isLoading = false
            }
        }
    }
    
    private func resolveRequest(id: String, action: String) {
        Task {
            do {
                _ = try await networkManager.resolveHITLRequest(id: id, action: action)
                await loadRequests(silent: true)
            } catch {
                print("Failed to resolve request \(id): \(error)")
            }
        }
    }
}

// MARK: - Request Card Component
struct HITLRequestCard: View {
    let request: HITLRequest
    let onResolve: (String) -> Void
    @State private var isProcessing = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header: Type badge and Date
            HStack {
                HStack(spacing: 8) {
                    Text(request.agent?.name ?? "Agent")
                        .font(.headline)
                    
                    getTypeBadge()
                }
                
                Spacer()
                
                Text(formatDate(request.createdAt))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            // Payload Container
            VStack(alignment: .leading, spacing: 6) {
                Text("PAYLOAD DETAILS")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                
                Text(formatPayload(request.payload))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.primary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondarySystemBackground)
                    .cornerRadius(8)
            }
            
            // Bottom Action buttons or Resolved logs
            if request.status == "pending" {
                HStack(spacing: 12) {
                    Button(action: {
                        isProcessing = true
                        onResolve("approve")
                    }) {
                        HStack {
                            Image(systemName: "checkmark")
                            Text("Approve")
                        }
                    }
                    .buttonStyle(PremiumButtonStyle(backgroundColor: .statusSuccess, cornerRadius: 8, isDisabled: isProcessing))
                    .disabled(isProcessing)
                    
                    Button(action: {
                        isProcessing = true
                        onResolve("reject")
                    }) {
                        HStack {
                            Image(systemName: "xmark")
                            Text("Reject")
                        }
                    }
                    .buttonStyle(PremiumButtonStyle(backgroundColor: .statusDestructive, cornerRadius: 8, isDisabled: isProcessing))
                    .disabled(isProcessing)
                }
            } else {
                HStack {
                    Spacer()
                    
                    if request.status == "approved" {
                        StatusBadge(text: "Approved", iconName: "checkmark.circle.fill", color: .statusSuccess)
                    } else {
                        StatusBadge(text: "Rejected", iconName: "xmark.circle.fill", color: .statusDestructive)
                    }
                    
                    if let resolved = request.resolvedAt {
                        Text("on \(formatDate(resolved))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(Color.secondarySystemGroupedBackground)
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.04), radius: 5, x: 0, y: 2)
    }
    
    // Format JSON string payload to pretty key-value description
    private func formatPayload(_ payloadStr: String) -> String {
        guard let data = payloadStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let prettyData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]),
              let prettyStr = String(data: prettyData, encoding: .utf8) else {
            return payloadStr
        }
        return prettyStr
    }
    
    private func getTypeBadge() -> some View {
        switch request.requestType {
        case "message":
            return StatusBadge(text: "Message", iconName: "bubble.left.fill", color: .brandPrimary)
        case "service_call":
            return StatusBadge(text: "Service Call", iconName: "bolt.fill", color: .brandSecondary)
        case "transaction":
            return StatusBadge(text: "Transaction", iconName: "creditcard.fill", color: .statusSuccess)
        default:
            return StatusBadge(text: request.requestType.uppercased(), iconName: nil, color: .secondary)
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

struct HITLQueueView_Previews: PreviewProvider {
    static var previews: some View {
        HITLQueueView()
    }
}
