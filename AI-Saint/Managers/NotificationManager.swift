import Foundation
import UserNotifications
import FirebaseMessaging

@Observable final class NotificationManager {
    static let shared = NotificationManager()
    
    private init() {
        // Debug log
        print("🔔 NotificationManager initialized")
    }
    
    func requestAuthorization() async throws {
        let options: UNAuthorizationOptions = [.alert, .sound, .badge]
        let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: options)
        
        // Debug log
        print("🔔 Notification authorization status: \(granted)")
        
        if granted {
            await MainActor.run {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }
    
    func getFCMToken() async throws -> String {
        guard let token = try? await Messaging.messaging().token() else {
            throw NSError(domain: "NotificationManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get FCM token"])
        }
        
        // Debug log
        print("🔔 FCM Token: \(token)")
        
        return token
    }
} 