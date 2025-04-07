import SwiftUI
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
import FirebaseMessaging
import GoogleSignIn
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, MessagingDelegate {
    // Rule: Always add debug logs
    
    // Property to access notification quote from elsewhere
    var latestQuote: String?
    
    // Store FCM token for access by NotificationManager
    var fcmToken: String?

    func application(_ application: UIApplication,
                    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Configure Firebase
        FirebaseConfig.configure()
        
        // Set messaging delegate
        Messaging.messaging().delegate = self
        
        // Set notification delegate
        UNUserNotificationCenter.current().delegate = self
        
        // Register for app lifecycle notifications
        NotificationCenter.default.addObserver(self, 
                                           selector: #selector(applicationDidBecomeActive), 
                                           name: UIApplication.didBecomeActiveNotification, 
                                           object: nil)
        
        // Always reset badge count on app launch
        print("📱 [AppDelegate] App launching, resetting badge count")
        UIApplication.shared.applicationIconBadgeNumber = 0
        NotificationManager.shared.unreadNotificationCount = 0
        NotificationManager.shared.saveUnreadNotificationCount()
        
        // If we have a token, update Firebase to show badge count as 0
        if let fcmToken = Messaging.messaging().fcmToken {
            print("📱 [AppDelegate] Updating badge count in Firestore to 0 on app launch")
            self.fcmToken = fcmToken
            NotificationManager.shared.updateDeviceBadgeCountInFirestore(fcmToken: fcmToken, badgeCount: 0)
            
            // Run diagnostic after short delay to allow Firestore update to complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                print("📱 [AppDelegate] Running badge count diagnostic")
                NotificationManager.shared.verifyDeviceTokenAndBadgeCount()
            }
        }
        
        return true
    }
    
    // Handle Google Sign-In URL
    func application(_ app: UIApplication,
                    open url: URL,
                    options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        // Debug log for URL handling
        print("Debug: Handling URL: \(url.absoluteString)")
        return GIDSignIn.sharedInstance.handle(url)
    }
    
    // MARK: - Push Notification Handling
    
    // Get FCM token
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        // Debug log
        print("📱 [AppDelegate] Firebase registration token: \(fcmToken ?? "nil")")
        
        // Store token for access by other components
        self.fcmToken = fcmToken
        
        // Store this token in Firestore for sending notifications to this device
        if let token = fcmToken {
            // Check if notifications are currently enabled according to system settings
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let isAuthorized = settings.authorizationStatus == .authorized
                print("📱 [AppDelegate] Current notification authorization status: \(isAuthorized)")
                
                // Update NotificationManager status
                DispatchQueue.main.async {
                    NotificationManager.shared.isNotificationsEnabled = isAuthorized
                    
                    // Force enable notifications if authorized
                    if isAuthorized {
                        NotificationManager.shared.updateDeviceToken(token, forceEnabled: true)
                    } else {
                        NotificationManager.shared.updateDeviceToken(token)
                    }
                    
                    // Run diagnostic after token is registered and updated
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        print("📱 [AppDelegate] Running badge count diagnostic after token update")
                        NotificationManager.shared.verifyDeviceTokenAndBadgeCount()
                    }
                }
            }
        }
    }
    
    // Handle incoming notifications while app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Debug log the notification
        let userInfo = notification.request.content.userInfo
        print("📱 [AppDelegate] Received notification while app in foreground: \(userInfo)")
        
        // Handle the notification with our manager
        if let quote = NotificationManager.shared.handleReceivedNotification(userInfo) {
            latestQuote = quote
        }
        
        // Show notification with badge
        completionHandler([.banner, .sound, .badge])
    }
    
    // Handle notification response when user taps notification
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        print("📱 [AppDelegate] User tapped notification: \(userInfo)")
        
        // Extract badge count from notification if available
        var badgeCount = 0
        if let aps = userInfo["aps"] as? [String: Any], 
           let badge = aps["badge"] as? Int {
            badgeCount = badge
            print("📱 [AppDelegate] Badge count from APS payload: \(badgeCount)")
        } else if let data = userInfo["data"] as? [String: Any],
                  let badgeString = data["badgeCount"] as? String,
                  let badge = Int(badgeString) {
            badgeCount = badge
            print("📱 [AppDelegate] Badge count from data payload: \(badgeCount)")
        }
        
        // Clear badge count when notification is tapped
        UIApplication.shared.applicationIconBadgeNumber = 0
        NotificationManager.shared.markNotificationsAsRead()
        
        // Handle the notification tap
        if let notificationData = NotificationManager.shared.handleNotificationTap(userInfo) {
            latestQuote = notificationData.quote
            
            // Post notification to open the quote view
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(
                    name: Notification.Name("OpenDailyQuoteView"),
                    object: nil,
                    userInfo: [
                        "quote": notificationData.quote,
                        "source": notificationData.source,
                        "fromNotification": true
                    ]
                )
            }
        }
        
        completionHandler()
    }
    
    // Called when APNs has assigned the device a unique token
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }
    
    // Called when APNs failed to register the device for push notifications
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Debug log
        print("❌ [AppDelegate] APNs registration failed: \(error.localizedDescription)")
    }
    
    // Handle app did become active notification
    @objc func applicationDidBecomeActive(_ notification: Notification) {
        // Reset badge count whenever app becomes active
        print("📱 [AppDelegate] App became active, resetting badge count")
        UIApplication.shared.applicationIconBadgeNumber = 0
        NotificationManager.shared.unreadNotificationCount = 0
        NotificationManager.shared.saveUnreadNotificationCount()
        
        // Ensure we update Firestore if we have a token
        if let token = self.fcmToken {
            print("📱 [AppDelegate] Explicitly updating Firestore badge count to 0")
            NotificationManager.shared.updateDeviceBadgeCountInFirestore(fcmToken: token, badgeCount: 0)
        } else if let token = Messaging.messaging().fcmToken {
            print("📱 [AppDelegate] Using Messaging.fcmToken to update Firestore badge count to 0")
            self.fcmToken = token
            NotificationManager.shared.updateDeviceBadgeCountInFirestore(fcmToken: token, badgeCount: 0)
        } else {
            print("📱 [AppDelegate] No FCM token available to update Firestore badge count")
        }
    }
}
