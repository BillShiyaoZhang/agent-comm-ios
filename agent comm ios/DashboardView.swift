import SwiftUI

struct DashboardView: View {
    @ObservedObject var networkManager = NetworkManager.shared
    @State private var agentCount = 0
    @State private var contactCount = 0
    @State private var pendingHitlCount = 0
    @State private var transactionCount = 0
    @State private var isLoading = false
    @State private var showSettings = false
    @State private var showServiceInvocation = false
    @State private var recentRequests: [HITLRequest] = []
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.systemGroupedBackground
                    .edgesIgnoringSafeArea(.all)
                
                ScrollView {
                    VStack(spacing: 20) {
                        // Quick Action Buttons
                        HStack(spacing: 12) {
                            Button(action: { showServiceInvocation = true }) {
                                HStack {
                                    Image(systemName: "bolt.fill")
                                    Text("Invoke Service")
                                        .bold()
                                }
                                .padding()
                                .frame(maxWidth: .infinity)
                                .background(LinearGradient(colors: [.brandPrimary, .brandPrimary.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .foregroundColor(.white)
                                .cornerRadius(12)
                                .shadow(color: .brandPrimary.opacity(0.3), radius: 5, x: 0, y: 3)
                            }
                            
                            // Navigation link to Services page
                            NavigationLink(destination: ServicesView(), isActive: $showServiceInvocation) {
                                EmptyView()
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 12)
                        
                        // Stat Cards Grid
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                            StatCard(
                                title: "Active Agents",
                                value: "\(agentCount)",
                                iconName: "cpu",
                                gradientColors: [.brandPrimary, .brandPrimary.opacity(0.6)]
                            )
                            
                            StatCard(
                                title: "Contacts",
                                value: "\(contactCount)",
                                iconName: "person.2.fill",
                                gradientColors: [.brandSecondary, .brandSecondary.opacity(0.6)]
                            )
                            
                            StatCard(
                                title: "Pending HITL",
                                value: "\(pendingHitlCount)",
                                iconName: "shield.fill",
                                gradientColors: [.statusWarning, .statusWarning.opacity(0.7)]
                            )
                            
                            StatCard(
                                title: "Transactions",
                                value: "\(transactionCount)",
                                iconName: "creditcard.fill",
                                gradientColors: [.statusSuccess, .statusSuccess.opacity(0.7)]
                            )
                        }
                        .padding(.horizontal)
                        
                        // Recent HITL Approvals Header
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Recent Requests")
                                    .font(.title2)
                                    .bold()
                                Spacer()
                                if isLoading {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .brandPrimary))
                                }
                            }
                            .padding(.horizontal)
                            
                            if recentRequests.isEmpty {
                                VStack(spacing: 12) {
                                    Image(systemName: "tray.fill")
                                        .font(.largeTitle)
                                        .foregroundColor(.secondary)
                                    Text("No pending requests")
                                        .foregroundColor(.secondary)
                                        .font(.subheadline)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                                .background(Color.secondarySystemGroupedBackground)
                                .cornerRadius(16)
                                .padding(.horizontal)
                            } else {
                                VStack(spacing: 12) {
                                    ForEach(recentRequests.prefix(4)) { request in
                                        RecentRequestRow(request: request)
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                }
                .refreshable {
                    await loadDashboardData()
                }
            }
            .navigationTitle("Dashboard")
            .crossPlatformToolbar(trailing: AnyView(Button(action: {
                showSettings = true
            }) {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundColor(.brandPrimary)
            }))
            // Settings navigation sheet
            .sheet(isPresented: $showSettings, onDismiss: {
                Task {
                    await loadDashboardData()
                }
            }) {
                SettingsView()
            }
        }
        .crossPlatformNavigationViewStyle()
        .onAppear {
            Task {
                await loadDashboardData()
            }
        }
    }
    
    // Concurrently load statistics
    private func loadDashboardData() async {
        DispatchQueue.main.async {
            self.isLoading = true
        }
        
        do {
            async let agents = networkManager.fetchAgents()
            async let contacts = networkManager.fetchContacts()
            async let requests = networkManager.fetchHITLRequests()
            async let transactions = networkManager.fetchTransactions()
            
            let (loadedAgents, loadedContacts, loadedRequests, loadedTxs) = try await (agents, contacts, requests, transactions)
            
            DispatchQueue.main.async {
                self.agentCount = loadedAgents.count
                self.contactCount = loadedContacts.count
                self.pendingHitlCount = loadedRequests.filter { $0.status == "pending" }.count
                self.transactionCount = loadedTxs.count
                self.recentRequests = loadedRequests
                self.isLoading = false
            }
        } catch {
            print("Failed to load dashboard metrics: \(error)")
            DispatchQueue.main.async {
                self.isLoading = false
            }
        }
    }
}

// MARK: - Stat Card Component
struct StatCard: View {
    let title: String
    let value: String
    let iconName: String
    let gradientColors: [Color]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(colors: gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 36, height: 36)
                    
                    Image(systemName: iconName)
                        .foregroundColor(.white)
                        .font(.body)
                }
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .bold()
            }
        }
        .padding()
        .background(Color.secondarySystemGroupedBackground)
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.04), radius: 5, x: 0, y: 2)
    }
}

// MARK: - Recent Request Row Component
struct RecentRequestRow: View {
    let request: HITLRequest
    
    var body: some View {
        HStack(spacing: 16) {
            // Icon according to type
            ZStack {
                Circle()
                    .fill(getBackgroundForType().opacity(0.15))
                    .frame(width: 44, height: 44)
                
                Image(systemName: getIconForType())
                    .foregroundColor(getBackgroundForType())
                    .font(.subheadline)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(request.agent?.name ?? "Agent Action")
                    .font(.headline)
                
                Text(request.requestType.uppercased())
                    .font(.caption2)
                    .bold()
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Status Badge
            if request.status == "pending" {
                StatusBadge(text: "Pending", iconName: "clock.fill", color: .statusWarning)
            } else if request.status == "approved" {
                StatusBadge(text: "Approved", iconName: "checkmark", color: .statusSuccess)
            } else {
                StatusBadge(text: "Rejected", iconName: "xmark", color: .statusDestructive)
            }
        }
        .padding()
        .background(Color.secondarySystemGroupedBackground)
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.02), radius: 3, x: 0, y: 1)
    }
    
    private func getIconForType() -> String {
        switch request.requestType {
        case "message": return "bubble.left.fill"
        case "service_call": return "bolt.fill"
        case "transaction": return "creditcard.fill"
        default: return "questionmark.circle.fill"
        }
    }
    
    private func getBackgroundForType() -> Color {
        switch request.requestType {
        case "message": return .brandPrimary
        case "service_call": return .brandSecondary
        case "transaction": return .statusSuccess
        default: return .secondary
        }
    }
}

struct DashboardView_Previews: PreviewProvider {
    static var previews: some View {
        DashboardView()
    }
}
