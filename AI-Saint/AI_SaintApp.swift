import SwiftUI
// Firebase is configured in AppDelegate

// Main app entry point
@main
struct DigitalConfessionApp: App {
    // MARK: - Properties
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var appCoordinator = AppCoordinator()
    
    // MARK: - Body
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ZStack {
                    // Content visibility controlled by coordinator
                    ContentView()
                        .opacity(appCoordinator.isContentVisible ? 1 : 0)
                    
                    // Splash screen visibility controlled by coordinator
                    if !appCoordinator.isContentVisible {
                        SplashScreen()
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.5), value: appCoordinator.isContentVisible)
                .onAppear {
                    appCoordinator.startApp()
                }
            }
            .preferredColorScheme(.light)
        }
    }
    
    init() {
        print("Debug: Digital Confession App initialized")
        // Firebase is configured in AppDelegate
    }
}

// MARK: - App Coordinator
@MainActor
class AppCoordinator: ObservableObject {
    @Published var isContentVisible = false
    
    func startApp() {
        // Ensure minimum splash display time
        Task {
            // Wait at least 1.5 seconds to show splash
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            
            // Transition to main content
            withAnimation {
                self.isContentVisible = true
            }
        }
    }
}

// MARK: - Splash Screen
struct SplashScreen: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
            
            VStack(spacing: 20) {
                // App logo
                TraditionalCross(
                    width: 60,
                    color: Color.yellow
                )
                .frame(width: 60, height: 96)
                
                Text("ConfessAI")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.primary)
                
                ProgressView()
                    .scaleEffect(1.2)
                    .padding(.top, 20)
            }
        }
    }
}
