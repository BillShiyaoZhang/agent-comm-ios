import SwiftUI

struct LoginView: View {
    @ObservedObject var networkManager = NetworkManager.shared
    @State private var email = ""
    @State private var password = ""
    @State private var serverUrl = ""
    @State private var isLoading = false
    @State private var errorMessage = ""
    @State private var showRegister = false
    @State private var isConfiguringServer = false
    
    var body: some View {
        NavigationView {
            ZStack {
                PremiumBackground()
                
                ScrollView {
                    VStack(spacing: 28) {
                        Spacer().frame(height: 40)
                        
                        // Header App Icon & Title
                        VStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 20)
                                    .fill(LinearGradient(colors: [.brandPrimary, .brandSecondary], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 80, height: 80)
                                
                                Image(systemName: "square.stack.3d.up.fill")
                                    .font(.system(size: 40))
                                    .foregroundColor(.white)
                            }
                            .shadow(color: .brandPrimary.opacity(0.4), radius: 10, x: 0, y: 5)
                            
                            Text("Agent Collab")
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                            
                            Text("AI Agent Collaboration & HITL Platform")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.6))
                        }
                        
                        // Error Alert Banner
                        if !errorMessage.isEmpty {
                            HStack {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundColor(.statusDestructive)
                                Text(errorMessage)
                                    .font(.subheadline)
                                    .foregroundColor(.white)
                                Spacer()
                            }
                            .padding()
                            .background(Color.statusDestructive.opacity(0.15))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.statusDestructive.opacity(0.3), lineWidth: 1)
                            )
                            .padding(.horizontal)
                        }
                        
                        // Form Card
                        VStack(spacing: 20) {
                            // Server URL Toggle Section
                            VStack(alignment: .leading, spacing: 8) {
                                Button(action: {
                                    withAnimation {
                                        isConfiguringServer.toggle()
                                    }
                                }) {
                                    HStack {
                                        Image(systemName: "server.rack")
                                            .foregroundColor(.brandSecondary)
                                        Text(isConfiguringServer ? "Hide Server Configuration" : "Configure Server URL")
                                            .font(.footnote)
                                            .bold()
                                            .foregroundColor(.brandSecondary)
                                        Spacer()
                                        Image(systemName: isConfiguringServer ? "chevron.up" : "chevron.down")
                                            .font(.footnote)
                                            .foregroundColor(.brandSecondary)
                                    }
                                }
                                
                                if isConfiguringServer {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("SERVER API BASE URL")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(.white.opacity(0.5))
                                        
                                        TextField("http://localhost:3000", text: $serverUrl)
                                            .crossPlatformKeyboardType(.url)
                                            .crossPlatformAutocapitalization()
                                            .disableAutocorrection(true)
                                            .foregroundColor(.white)
                                            .padding()
                                            .background(Color.white.opacity(0.08))
                                            .cornerRadius(10)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
                                            )
                                    }
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                                    .padding(.top, 4)
                                }
                            }
                            .padding(.bottom, 4)
                            
                            // Email Input
                            VStack(alignment: .leading, spacing: 6) {
                                Text("EMAIL ADDRESS")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white.opacity(0.5))
                                
                                TextField("you@example.com", text: $email)
                                    .crossPlatformKeyboardType(.emailAddress)
                                    .crossPlatformAutocapitalization()
                                    .disableAutocorrection(true)
                                    .foregroundColor(.white)
                                    .padding()
                                    .background(Color.white.opacity(0.08))
                                    .cornerRadius(10)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                                    )
                            }
                            
                            // Password Input
                            VStack(alignment: .leading, spacing: 6) {
                                Text("PASSWORD")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white.opacity(0.5))
                                
                                SecureField("••••••••", text: $password)
                                    .foregroundColor(.white)
                                    .padding()
                                    .background(Color.white.opacity(0.08))
                                    .cornerRadius(10)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                                    )
                            }
                            
                            // Login Button
                            Button(action: handleLogin) {
                                HStack {
                                    if isLoading {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                            .padding(.trailing, 8)
                                    }
                                    Text(isLoading ? "Signing In..." : "Sign In")
                                        .bold()
                                }
                            }
                            .buttonStyle(PremiumButtonStyle(backgroundColor: .brandPrimary, isDisabled: isLoading))
                            .disabled(isLoading)
                            
                        }
                        .padding(24)
                        .glassCardStyle()
                        .padding(.horizontal)
                        
                        // Register Link
                        NavigationLink(destination: RegisterView(), isActive: $showRegister) {
                            Button(action: { showRegister = true }) {
                                HStack {
                                    Text("Don't have an account?")
                                        .foregroundColor(.white.opacity(0.6))
                                    Text("Sign Up")
                                        .bold()
                                        .foregroundColor(.brandSecondary)
                                }
                                .font(.subheadline)
                            }
                        }
                        .padding(.top, 8)
                        
                        Spacer()
                    }
                }
            }
            .crossPlatformNavigationBarHidden(true)
        }
        .crossPlatformNavigationViewStyle()
        .onAppear {
            self.serverUrl = networkManager.baseUrl
            self.errorMessage = ""
        }
    }
    
    private func handleLogin() {
        guard !email.isEmpty, !password.isEmpty else {
            errorMessage = "Please fill in all fields"
            return
        }
        
        errorMessage = ""
        isLoading = true
        
        // Update URL first
        if !serverUrl.isEmpty {
            networkManager.baseUrl = serverUrl
        }
        
        Task {
            do {
                try await networkManager.login(email: email, password: password)
                DispatchQueue.main.async {
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}

struct LoginView_Previews: PreviewProvider {
    static var previews: some View {
        LoginView()
            .preferredColorScheme(.dark)
    }
}
