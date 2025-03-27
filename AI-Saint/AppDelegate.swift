import SwiftUI
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
import GoogleSignIn

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        print("[AppDelegate] Configuring app")
        FirebaseConfig.configure()
        return true
    }
    
    // Handle Google Sign-In URL
    func application(_ app: UIApplication,
                    open url: URL,
                    options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        // Debug log for URL handling
        print("Debug: Handling URL: \(url.absoluteString)") // Debug log
        return GIDSignIn.sharedInstance.handle(url)
    }
}
