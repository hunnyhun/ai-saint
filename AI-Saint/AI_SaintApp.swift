import SwiftUI
// Firebase is configured in AppDelegate

// Main app entry point
@main
struct DigitalConfessionApp: App {
    // MARK: - Properties
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    // @StateObject private var appCoordinator = AppCoordinator() // REMOVE OR COMMENT OUT
    
    // Track language changes to restart app
    @Environment(\.locale) private var locale
    @State private var currentLocaleId: String?
    
    // MARK: - Body
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                // REMOVE the surrounding ZStack if it's no longer needed,
                // or just display ContentView directly
                ContentView()
                    // .opacity(appCoordinator.isContentVisible ? 1 : 0) // REMOVE
                    .environment(\.scenePhase, .active) // Ensure the app knows it's active
                
                // REMOVE the conditional splash screen block:
                // if !appCoordinator.isContentVisible {
                //    SplashScreen()
                //        .transition(.opacity)
                // }
                
                // .animation(.easeInOut(duration: 0.5), value: appCoordinator.isContentVisible) // REMOVE
                .onAppear {
                    // Rule: Always add debug logs
                    print("📱 [App] Initial app appear, locale: \(locale.identifier)")
                    currentLocaleId = locale.identifier
                    // appCoordinator.startApp() // REMOVE
                }
                .onChange(of: locale) {
                    // Rule: Always add debug logs
                    print("📱 [App] Locale changed from \(currentLocaleId ?? "unknown") to \(locale.identifier)")
                    // Check if the language part has actually changed
                    let oldLanguage = currentLocaleId?.split(separator: "_").first.map(String.init)
                    let newLanguage = locale.identifier.split(separator: "_").first.map(String.init)
                    
                    if currentLocaleId != locale.identifier && (oldLanguage != newLanguage || oldLanguage == nil) {
                        // Force restart the view to apply new language
                        print("📱 [App] Language changed, restarting UI (Note: Full restart might require different approach now)")
                        // REMOVE the logic involving appCoordinator.isContentVisible:
                        // appCoordinator.isContentVisible = false
                        // DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        //    appCoordinator.isContentVisible = true
                        //    print("📱 [App] UI restarted with new language: \(locale.identifier)")
                        // }
                        // TODO: You might need a different mechanism to force a UI update on language change if needed.
                    } else {
                        print("📱 [App] Only region changed, not restarting UI")
                    }
                    currentLocaleId = locale.identifier
                }
                .onOpenURL { url in
                    // Handle deep links if needed for notifications
                    print("📱 [App] Handling URL: \(url)")
                }
            }
            .preferredColorScheme(.light)
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DailyQuoteNotificationTapped"))) { notification in
                // Handle notification when app is launched via notification
                print("📱 [App] Handling quote notification from app launch")
            }
        }
    }
    
    init() {
        print("Debug: Digital Confession App initialized")
        // Firebase is configured in AppDelegate
    }
}

// MARK: - App Coordinator
// REMOVE OR COMMENT OUT THE ENTIRE AppCoordinator CLASS
/*
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
*/

// MARK: - Splash Screen
// REMOVE OR COMMENT OUT THE ENTIRE SplashScreen STRUCT
/*
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
                
                // Use static text since extensions may not be loaded yet during startup
                Text("AI Saint")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.yellow)
                
                ProgressView()
                    .scaleEffect(1.2)
                    .padding(.top, 20)
            }
        }
    }
}
*/
