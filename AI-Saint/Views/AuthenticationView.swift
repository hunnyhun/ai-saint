import SwiftUI
import RevenueCat

// MARK: - Background Components
struct HolyBackground: View {
    @State private var animateGradient = false
    
    var body: some View {
        // Base gradient
        LinearGradient(
            colors: [
                Color(hex: "FFEF00"),  // Bright gold
                Color(hex: "FFE066"),  // Light gold
                Color(hex: "FFFFC5"),  // Warm yellow
                Color(hex: "FFE066")   // Light gold
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .hueRotation(.degrees(animateGradient ? 2 : 0))
        .onAppear {
            withAnimation(.linear(duration: 8.0).repeatForever(autoreverses: true)) {
                animateGradient.toggle()
            }
        }
        .ignoresSafeArea()
    }
}

struct HolySparkles: View {
    @State private var animate = false
    
    var body: some View {
        ZStack {
            // Background sparkles - increased from 40 to 60 with wider range
            ForEach(0..<60) { index in
                Circle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: CGFloat.random(in: 1.5...4.5))
                    .offset(
                        x: CGFloat.random(in: -300...300),
                        y: CGFloat.random(in: -600...600)
                    )
                    .animation(
                        Animation.linear(duration: Double.random(in: 4...9))
                            .repeatForever(autoreverses: true)
                            .delay(Double.random(in: 0...4)),
                        value: animate
                    )
            }
            
            // Twinkling sparkles - increased from 25 to 35 with more motion
            ForEach(0..<35) { index in
                Circle()
                    .fill(Color.white.opacity(0.4))
                    .frame(width: CGFloat.random(in: 1...3.5))
                    .offset(
                        x: CGFloat.random(in: -250...250),
                        y: CGFloat.random(in: -500...500)
                    )
                    .scaleEffect(animate ? CGFloat.random(in: 1.1...1.4) : CGFloat.random(in: 0.4...0.7))
                    .animation(
                        Animation.easeInOut(duration: Double.random(in: 1.5...4))
                            .repeatForever(autoreverses: true)
                            .delay(Double.random(in: 0...3)),
                        value: animate
                    )
            }
            
            // Small fast-moving dots - new element
            ForEach(0..<20) { index in
                Circle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: CGFloat.random(in: 1...2))
                    .offset(
                        x: CGFloat.random(in: -280...280) + (animate ? CGFloat.random(in: -40...40) : 0),
                        y: CGFloat.random(in: -550...550) + (animate ? CGFloat.random(in: -40...40) : 0)
                    )
                    .animation(
                        Animation.easeInOut(duration: Double.random(in: 0.8...1.5))
                            .repeatForever(autoreverses: true),
                        value: animate
                    )
            }
            
            // Glowing holy lights - increased from 10 to 15 with more variety
            ForEach(0..<15) { index in
                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [.white, .white.opacity(0)]),
                            center: .center,
                            startRadius: 0,
                            endRadius: 5
                        )
                    )
                    .frame(width: CGFloat.random(in: 4...9))
                    .offset(
                        x: CGFloat.random(in: -240...240),
                        y: CGFloat.random(in: -480...480)
                    )
                    .opacity(animate ? CGFloat.random(in: 0.6...0.8) : CGFloat.random(in: 0.2...0.4))
                    .scaleEffect(animate ? CGFloat.random(in: 0.9...1.2) : CGFloat.random(in: 0.7...0.9))
                    .animation(
                        Animation.easeInOut(duration: Double.random(in: 2...6))
                            .repeatForever(autoreverses: true)
                            .delay(Double.random(in: 0...3)),
                        value: animate
                    )
            }
            
            // Cross-shaped sparkles - increased from 8 to 12 with more motion
            ForEach(0..<12) { index in
                Image(systemName: "sparkle")
                    .font(.system(size: CGFloat.random(in: 10...20)))
                    .foregroundColor(.white.opacity(0.5))
                    .offset(
                        x: CGFloat.random(in: -220...220) + (animate ? CGFloat.random(in: -25...25) : 0),
                        y: CGFloat.random(in: -450...450) + (animate ? CGFloat.random(in: -25...25) : 0)
                    )
                    .opacity(animate ? CGFloat.random(in: 0.7...0.9) : CGFloat.random(in: 0.3...0.5))
                    .scaleEffect(animate ? CGFloat.random(in: 1.0...1.3) : CGFloat.random(in: 0.7...0.9))
                    .rotationEffect(Angle(degrees: animate ? Double.random(in: -15...15) : 0))
                    .animation(
                        Animation.easeInOut(duration: Double.random(in: 2...4))
                            .repeatForever(autoreverses: true)
                            .delay(Double.random(in: 0...2)),
                        value: animate
                    )
            }
            
            // Additional star symbols - new element
            ForEach(0..<8) { index in
                Image(systemName: "star.fill")
                    .font(.system(size: CGFloat.random(in: 4...8)))
                    .foregroundColor(.white.opacity(0.4))
                    .offset(
                        x: CGFloat.random(in: -200...200),
                        y: CGFloat.random(in: -400...400)
                    )
                    .opacity(animate ? CGFloat.random(in: 0.6...0.8) : CGFloat.random(in: 0.2...0.4))
                    .scaleEffect(animate ? CGFloat.random(in: 1.0...1.2) : CGFloat.random(in: 0.6...0.8))
                    .animation(
                        Animation.easeInOut(duration: Double.random(in: 3...5))
                            .repeatForever(autoreverses: true)
                            .delay(Double.random(in: 0...2)),
                        value: animate
                    )
            }
        }
        .onAppear { 
            // Start animation with debug log
            print("DEBUG: [HolySparkles] Starting animation with enhanced particles")
            animate.toggle() 
        }
    }
}

struct AuthenticationView: View {
    // MARK: - Properties
    @State private var isLoading = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss
    @State private var animateCross = false
    
    // MARK: - Environment
    let authManager = AuthenticationManager.shared
    
    // MARK: - Body
    var body: some View {
        NavigationStack {
            ZStack {
                // Holy Background
                HolyBackground()
                
                // Holy Sparkles
                HolySparkles()
                
                // Main Content
                VStack(spacing: 0) {
                    // Cross and Title
                    VStack(spacing: 40) { // Decreased spacing from 80 to 40 (half)
                        // Traditional Cross
                        TraditionalCross()
                            .padding(.top, 40) // Reduced from 60 to 40 to move up
                        
                        Text("ConfessAI")
                            .font(.custom("Avenir-Heavy", size: 44))
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .shadow(color: .white.opacity(0.3), radius: 10)
                    }
                    .padding(.top, 40) // Reduced from 60 to 40 to move everything up
                    
                    Text("Begin your digital confession")
                        .font(.custom("Avenir-Medium", size: 22))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.top, 15)
                    
                    // Error Message
                    if let error = errorMessage {
                        Text(error)
                            .font(.custom("Avenir", size: 16))
                            .foregroundColor(.red.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                    
                    Spacer()
                    
                    // Authentication Buttons
                    VStack(spacing: 16) {
                        // Google Sign In
                        Button(action: handleGoogleSignIn) {
                            HStack {
                                Image(systemName: "g.circle.fill")
                                    .font(.title2)
                                Text("Continue with Google")
                                    .font(.custom("Avenir-Medium", size: 18))
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.ultraThinMaterial)
                            .foregroundStyle(.white)
                            .cornerRadius(25)
                            .shadow(color: .black.opacity(0.1), radius: 10)
                        }
                        .opacity(isLoading ? 0.6 : 1.0)
                        .animation(.easeInOut(duration: 0.2), value: isLoading)
                        
                        // Apple Sign In
                        Button(action: handleAppleSignIn) {
                            HStack {
                                Image(systemName: "apple.logo")
                                    .font(.title2)
                                Text("Continue with Apple")
                                    .font(.custom("Avenir-Medium", size: 18))
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.ultraThinMaterial)
                            .foregroundStyle(.white)
                            .cornerRadius(25)
                            .shadow(color: .black.opacity(0.1), radius: 10)
                        }
                        .opacity(isLoading ? 0.6 : 1.0)
                        .animation(.easeInOut(duration: 0.2), value: isLoading)
                        
                        // Fixed space for loading indicator
                        ZStack {
                            if isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(1.5)
                                    .transition(.opacity)
                            }
                        }
                        .frame(height: 44) // Fixed height for the loading indicator space
                        .animation(.easeInOut(duration: 0.3), value: isLoading)
                    }
                    .padding(.horizontal, 30)
                    .padding(.bottom, 50)
                    .disabled(isLoading)
                }
            }
            .interactiveDismissDisabled(true)
            .onChange(of: authManager.isAuthenticated) { _, isAuthenticated in
                if isAuthenticated {
                    dismiss()
                }
            }
        }
    }
    
    // MARK: - Actions
    private func handleGoogleSignIn() {
        isLoading = true
        print("DEBUG: [AuthView] Attempting Google sign in")
        
        Task {
            do {
                try await authManager.signInWithGoogle()
                print("DEBUG: [AuthView] Google sign in successful")
            } catch {
                // Only show error if it's not a cancellation
                if !isCancellationError(error) {
                    errorMessage = error.localizedDescription
                    print("ERROR: [AuthView] Google sign in failed: \(error.localizedDescription)")
                } else {
                    print("INFO: [AuthView] Google sign in was cancelled by user")
                }
            }
            isLoading = false
        }
    }
    
    private func handleAppleSignIn() {
        isLoading = true
        print("DEBUG: [AuthView] Attempting Apple sign in")
        
        Task {
            do {
                try await authManager.signInWithApple()
                print("DEBUG: [AuthView] Apple sign in successful")
            } catch {
                // Only show error if it's not a cancellation
                if !isCancellationError(error) {
                    errorMessage = error.localizedDescription
                    print("ERROR: [AuthView] Apple sign in failed: \(error.localizedDescription)")
                } else {
                    print("INFO: [AuthView] Apple sign in was cancelled by user")
                }
            }
            isLoading = false
        }
    }
    
    // Helper to check if an error is a cancellation
    private func isCancellationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        
        // Check for common cancellation error codes and domains
        if nsError.domain == "com.google.GIDSignIn" && nsError.code == -5 {
            return true // Google Sign In cancellation
        }
        
        if nsError.domain == "com.apple.AuthenticationServices.AuthorizationError" && 
           (nsError.code == 1000 || nsError.code == 1001) {
            return true // Apple Sign In cancellation
        }
        
        // Check for common cancellation error messages
        let errorString = error.localizedDescription.lowercased()
        return errorString.contains("cancel") || 
               errorString.contains("cancelled") || 
               errorString.contains("canceled")
    }
}

// MARK: - Color Extension
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Preview
#Preview {
    AuthenticationView()
} 