import SwiftUI

struct ContentView: View {
    @ObservedObject var networkManager = NetworkManager.shared
    @State private var isCheckingSession = true
    
    var body: some View {
        Group {
            if isCheckingSession {
                ZStack {
                    PremiumBackground()
                    VStack(spacing: 20) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.5)
                        Text("Verifying Session...")
                            .foregroundColor(.white.opacity(0.8))
                            .font(.headline)
                    }
                }
            } else if networkManager.isAuthenticated {
                MainTabView()
            } else {
                LoginView()
            }
        }
        .onAppear {
            verifyAuthentication()
        }
    }
    
    private func verifyAuthentication() {
        Task {
            do {
                try await networkManager.checkSession()
            } catch {
                print("Session verification failed: \(error)")
            }
            DispatchQueue.main.async {
                self.isCheckingSession = false
            }
        }
    }
}

// MARK: - Main Tab View
struct MainTabView: View {
    @State private var selectedTab = 0
    
    init() {
        #if os(iOS)
        // Set standard tab bar appearance for iOS
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        UITabBar.appearance().scrollEdgeAppearance = appearance
        UITabBar.appearance().standardAppearance = appearance
        #endif
    }
    
    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView()
                .tabItem {
                    Label("Dashboard", systemImage: "square.grid.2x2.fill")
                }
                .tag(0)
            
            AgentsView()
                .tabItem {
                    Label("Agents", systemImage: "cpu")
                }
                .tag(1)
            
            MessagesView()
                .tabItem {
                    Label("Messages", systemImage: "bubble.left.and.bubble.right.fill")
                }
                .tag(2)
            
            HITLQueueView()
                .tabItem {
                    Label("HITL Queue", systemImage: "shield.fill")
                }
                .tag(3)
            
            TransactionsView()
                .tabItem {
                    Label("Transactions", systemImage: "creditcard.fill")
                }
                .tag(4)
        }
        .accentColor(.brandPrimary)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .preferredColorScheme(.dark)
    }
}
