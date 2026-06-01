import SwiftUI

struct RegisterView: View {
    @Environment(\.presentationMode) var presentationMode
    @ObservedObject var networkManager = NetworkManager.shared
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isLoading = false
    @State private var successMessage = ""
    @State private var errorMessage = ""
    
    var body: some View {
        ZStack {
            PremiumBackground()
            
            ScrollView {
                VStack(spacing: 24) {
                    Spacer().frame(height: 20)
                    
                    // Title section
                    VStack(spacing: 8) {
                        Text("Create Account")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        
                        Text("Join Agent Collab Platform")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.6))
                    }
                    
                    // Messages
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
                    
                    if !successMessage.isEmpty {
                        VStack(spacing: 16) {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.statusSuccess)
                                Text(successMessage)
                                    .font(.subheadline)
                                    .bold()
                                    .foregroundColor(.white)
                                Spacer()
                            }
                            
                            Button(action: {
                                presentationMode.wrappedValue.dismiss()
                            }) {
                                Text("Back to Sign In")
                                    .font(.subheadline)
                                    .bold()
                            }
                            .buttonStyle(PremiumButtonStyle(backgroundColor: .brandSecondary))
                        }
                        .padding()
                        .background(Color.statusSuccess.opacity(0.15))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.statusSuccess.opacity(0.3), lineWidth: 1)
                        )
                        .padding(.horizontal)
                    }
                    
                    if successMessage.isEmpty {
                        // Registration Card
                        VStack(spacing: 20) {
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
                                
                                SecureField("Minimum 8 characters", text: $password)
                                    .foregroundColor(.white)
                                    .padding()
                                    .background(Color.white.opacity(0.08))
                                    .cornerRadius(10)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                                    )
                            }
                            
                            // Confirm Password Input
                            VStack(alignment: .leading, spacing: 6) {
                                Text("CONFIRM PASSWORD")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white.opacity(0.5))
                                
                                SecureField("••••••••", text: $confirmPassword)
                                    .foregroundColor(.white)
                                    .padding()
                                    .background(Color.white.opacity(0.08))
                                    .cornerRadius(10)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                                    )
                            }
                            
                            // Register Button
                            Button(action: handleRegister) {
                                HStack {
                                    if isLoading {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                            .padding(.trailing, 8)
                                    }
                                    Text(isLoading ? "Creating Account..." : "Create Account")
                                        .bold()
                                }
                            }
                            .buttonStyle(PremiumButtonStyle(backgroundColor: .brandSecondary, isDisabled: isLoading))
                            .disabled(isLoading)
                        }
                        .padding(24)
                        .glassCardStyle()
                        .padding(.horizontal)
                    }
                    
                    // Back link
                    Button(action: {
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        Text("Already have an account? Sign In")
                            .font(.subheadline)
                            .bold()
                            .foregroundColor(.brandPrimary)
                    }
                    .padding(.top, 8)
                    
                    Spacer()
                }
            }
        }
        .crossPlatformNavigationBarTitleDisplayModeInline()
        .navigationBarBackButtonHidden(true)
        .crossPlatformToolbar(leading: AnyView(Button(action: {
            presentationMode.wrappedValue.dismiss()
        }) {
            HStack {
                Image(systemName: "chevron.left")
                Text("Back")
            }
            .foregroundColor(.white)
        }))
    }
    
    private func handleRegister() {
        guard !email.isEmpty, !password.isEmpty, !confirmPassword.isEmpty else {
            errorMessage = "Please fill in all fields"
            return
        }
        
        guard password == confirmPassword else {
            errorMessage = "Passwords do not match"
            return
        }
        
        guard password.count >= 8 else {
            errorMessage = "Password must be at least 8 characters"
            return
        }
        
        errorMessage = ""
        successMessage = ""
        isLoading = true
        
        Task {
            do {
                try await networkManager.register(email: email, password: password)
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.successMessage = "Account created successfully! Please sign in."
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

struct RegisterView_Previews: PreviewProvider {
    static var previews: some View {
        RegisterView()
            .preferredColorScheme(.dark)
    }
}
