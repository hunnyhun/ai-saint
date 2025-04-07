import SwiftUI
import UserNotifications
import FirebaseFirestore
import UIKit // For UIApplication
import FirebaseMessaging
// Let's just use Firebase without specific modules since that's what's working in other files
// Rule: Always add debug logs for easier debug

// MARK: - Notification Manager
@Observable final class NotificationManager {
    // Rule: Always add debug logs
    
    // Singleton instance
    static let shared = NotificationManager()
    
    // Properties
    var isNotificationsEnabled = false
    var unreadNotificationCount = 0 // Track number of unread notifications
    private let db = Firestore.firestore()
    
    // MARK: - Initialization
    private init() {
        // Load saved states
        loadNotificationStatus()
        loadUnreadNotificationCount()
        
        // Debug log for initialization
        print("📱 [NotificationManager] Initialized with unread count: \(unreadNotificationCount)")
        
        // Register for app lifecycle notifications to help manage badge state
        NotificationCenter.default.addObserver(self, 
                                           selector: #selector(handleAppDidBecomeActive), 
                                           name: UIApplication.didBecomeActiveNotification, 
                                           object: nil)
        
        // Add observer for app entering background to ensure badge count is synchronized
        NotificationCenter.default.addObserver(self, 
                                           selector: #selector(handleAppDidEnterBackground), 
                                           name: UIApplication.didEnterBackgroundNotification, 
                                           object: nil)
    }
    
    // App lifecycle handler - App became active
    @objc private func handleAppDidBecomeActive() {
        print("📱 [NotificationManager] App became active. Current unread count: \(unreadNotificationCount)")
        
        // Reset badge count in Firestore when app becomes active
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate,
           let fcmToken = appDelegate.fcmToken {
            // Reset badge count to zero in Firestore when app is opened
            updateDeviceBadgeCountInFirestore(fcmToken: fcmToken, badgeCount: 0)
            print("📱 [NotificationManager] Reset badge count in Firestore to 0")
        }
        
        // Ensure synchronization
        synchronizeBadgeCount() 
    }
    
    // App lifecycle handler - App entered background
    @objc private func handleAppDidEnterBackground() {
        // Ensure badge count is synchronized when app enters background
        print("📱 [NotificationManager] App entered background, synchronizing badge count: \(unreadNotificationCount)")
        synchronizeBadgeCount()
    }
    
    // MARK: - Notification Count Management
    
    // Increment notification count
    func incrementUnreadCount() {
        // Increment count 
        unreadNotificationCount += 1
        
        // Debug log
        print("📱 [NotificationManager] Incrementing unread count to: \(unreadNotificationCount)")
        
        // Update app badge
        UIApplication.shared.applicationIconBadgeNumber = unreadNotificationCount
        
        // Save to persistent storage
        saveUnreadNotificationCount()
    }
    
    // Set notification count to specific value
    func setUnreadCount(_ count: Int) {
        // Set count
        unreadNotificationCount = count
        
        // Debug log
        print("📱 [NotificationManager] Setting unread count to: \(count)")
        
        // Update app badge
        UIApplication.shared.applicationIconBadgeNumber = count
        
        // Save to persistent storage
        saveUnreadNotificationCount()
    }
    
    // Reset notification count - Call this when the user has viewed the relevant content
    // Renamed from clearUnreadCount
    func markNotificationsAsRead() {
        if unreadNotificationCount > 0 {
            // Reset unread count
            unreadNotificationCount = 0
            UIApplication.shared.applicationIconBadgeNumber = 0
            
            // Debug log
            print("📱 [NotificationManager] Marked notifications as read, cleared unread count")
            
            // Save to persistent storage
            saveUnreadNotificationCount()
            
            // Clear delivered notifications from the Notification Center
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            
            // Also update the badge count in Firestore for this device
            if let appDelegate = UIApplication.shared.delegate as? AppDelegate,
               let fcmToken = appDelegate.fcmToken {
                print("📱 [NotificationManager] Updating Firestore badge count to 0 from markNotificationsAsRead")
                updateDeviceBadgeCountInFirestore(fcmToken: fcmToken, badgeCount: 0)
            } else {
                print("📱 [NotificationManager] Cannot update Firestore: No FCM token available")
            }
        } else {
            print("📱 [NotificationManager] No notifications to mark as read (count already 0)")
        }
    }
    
    // Synchronize badge count with system
    func synchronizeBadgeCount() {
        // Ensure app badge count matches our internal count
        print("📱 [NotificationManager] Synchronizing badge count: \(unreadNotificationCount)")
        UIApplication.shared.applicationIconBadgeNumber = unreadNotificationCount
    }
    
    // MARK: - Handle Received Notification
    func handleReceivedNotification(_ userInfo: [AnyHashable: Any]) -> String? {
        // Debug log
        print("📱 [NotificationManager] Handling received notification")
        
        // When app is in foreground, increment badge instead of using server value
        // This prevents continuing from previously high values
        incrementUnreadCount()
        
        // Sync our badge count back to Firebase so server stays in sync
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate,
           let fcmToken = appDelegate.fcmToken {
            updateDeviceBadgeCountInFirestore(fcmToken: fcmToken, badgeCount: unreadNotificationCount)
            print("📱 [NotificationManager] Updated Firestore badge count to: \(unreadNotificationCount)")
        }
        
        // Extract quote from notification payload
        if let data = userInfo["data"] as? [String: Any],
           let quote = data["quote"] as? String {
            return quote
        }
        
        return nil
    }
    
    // MARK: - Handle Notification Tap
    func handleNotificationTap(_ userInfo: [AnyHashable: Any]) -> (quote: String, source: String)? {
        // Extract quote from notification payload
        if let data = userInfo["data"] as? [String: Any],
           let quote = data["quote"] as? String {
            
            // Get source information
            let source = data["source"] as? String ?? "notification"
            
            // Mark notifications as read when tapped
            markNotificationsAsRead()
            
            return (quote: quote, source: source)
        }
        
        return nil
    }
    
    // MARK: - Request Permission
    func requestNotificationPermission() async -> Bool {
        // Rule: Always add debug logs
        print("📱 [NotificationManager] Requesting notification permission")
        
        do {
            // Configure notification center
            let center = UNUserNotificationCenter.current()
            
            // Request authorization for alerts, badges, and sounds
            let options: UNAuthorizationOptions = [.alert, .badge, .sound]
            let granted = try await center.requestAuthorization(options: options)
            
            // Debug log
            print("📱 [NotificationManager] Notification permission granted: \(granted)")
            
            if granted {
                // Register for remote notifications on main thread
                await MainActor.run {
                    UIApplication.shared.registerForRemoteNotifications()
                }
                
                // Update local state
                isNotificationsEnabled = granted
                saveNotificationStatus()
                
                // Update device token if available
                if let appDelegate = UIApplication.shared.delegate as? AppDelegate,
                   let fcmToken = appDelegate.fcmToken {
                    // Force set notificationsEnabled to true before saving token
                    updateDeviceToken(fcmToken, forceEnabled: true)
                }
            }
            
            return granted
        } catch {
            print("📱 [NotificationManager] Error requesting notification permission: \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - Enable Notifications (Legacy method - kept for backward compatibility)
    func enableNotifications() async -> Bool {
        // Simply forward to requestNotificationPermission
        print("📱 [NotificationManager] enableNotifications() called - redirecting to requestNotificationPermission()")
        return await requestNotificationPermission()
    }
    
    // MARK: - Update Device Token
    func updateDeviceToken(_ fcmToken: String, forceEnabled: Bool? = nil) {
        guard let userId = UserStatusManager.shared.state.userId else {
            print("📱 [NotificationManager] Cannot update device token: No user ID")
            return
        }
        
        // Get timezone information
        let timeZone = TimeZone.current
        let timeZoneName = timeZone.identifier
        let timeZoneOffset = timeZone.secondsFromGMT() / 3600
        
        // Determine notification enabled status
        // Use forced value if provided (can be true or false), otherwise use current setting
        let enabled: Bool
        if let forceValue = forceEnabled {
            enabled = forceValue
            print("📱 [NotificationManager] Using forced notification status: \(enabled)")
        } else {
            enabled = isNotificationsEnabled
            print("📱 [NotificationManager] Using current notification status: \(enabled)")
        }
        
        print("📱 [NotificationManager] Updating device token with notificationsEnabled: \(enabled)")
        
        // Save token to Firestore
        let deviceRef = db.collection("users").document(userId).collection("devices").document(fcmToken)
        
        deviceRef.setData([
            "token": fcmToken,
            "platform": "iOS",
            "notificationsEnabled": enabled,
            "timeZone": timeZoneName,
            "timeZoneOffset": timeZoneOffset,
            "badgeCount": 0, // Always start with zero when registering device
            "lastUpdated": FieldValue.serverTimestamp()
        ], merge: true)
    }
    
    // Helper to update only the badge count in Firestore
    func updateDeviceBadgeCountInFirestore(fcmToken: String, badgeCount: Int) {
        guard let userId = UserStatusManager.shared.state.userId else {
            print("📱 [NotificationManager] Cannot update device badge count: No user ID")
            return
        }
        
        print("📱 [NotificationManager] Updating badge count in Firestore to \(badgeCount) for token: \(fcmToken.prefix(10))...")
        let deviceRef = db.collection("users").document(userId).collection("devices").document(fcmToken)
        deviceRef.updateData([
            "badgeCount": badgeCount,
            "lastUpdated": FieldValue.serverTimestamp()
        ]) { error in
            if let error = error {
                print("📱 [NotificationManager] Error updating badge count in Firestore: \(error.localizedDescription)")
            } else {
                print("📱 [NotificationManager] Successfully updated badge count in Firestore to \(badgeCount)")
                
                // Verify the update was successful by reading the document
                deviceRef.getDocument { (document, error) in
                    if let document = document, document.exists {
                        if let data = document.data(), let storedBadge = data["badgeCount"] as? Int {
                            print("📱 [NotificationManager] Verified Firestore badge count is now: \(storedBadge)")
                        } else {
                            print("📱 [NotificationManager] Could not read badge count from document")
                        }
                    } else {
                        print("📱 [NotificationManager] Device document does not exist")
                    }
                }
            }
        }
    }
    
    // MARK: - Check Notification Status
    // This function now directly reflects the system status and updates local state and Firestore accordingly.
    func checkNotificationStatus() async -> Bool {
        let current = UNUserNotificationCenter.current()
        let settings = await current.notificationSettings()
        
        // Get the current system authorization status
        let isAuthorized = settings.authorizationStatus == .authorized
        
        // Rule: Always add debug logs
        print("📱 [NotificationManager] System notification status check: \(isAuthorized ? "authorized" : "not authorized"), Current app state: \(isNotificationsEnabled)")
        
        // Check if the system status differs from our stored state
        if isAuthorized != isNotificationsEnabled {
            print("📱 [NotificationManager] System status (\(isAuthorized)) differs from app state (\(isNotificationsEnabled)). Updating app state.")
            
            // Update the local state
            isNotificationsEnabled = isAuthorized
            saveNotificationStatus()
            
            // If newly authorized, ensure we register and update token
            if isAuthorized {
                // Register for remote notifications on main thread
                await MainActor.run {
                    UIApplication.shared.registerForRemoteNotifications()
                }
                // Update Firebase token with enabled status
                if let appDelegate = UIApplication.shared.delegate as? AppDelegate,
                   let fcmToken = appDelegate.fcmToken {
                    updateDeviceToken(fcmToken, forceEnabled: true)
                }
            } else {
                // If newly de-authorized (e.g., user changed in Settings), update token
                if let appDelegate = UIApplication.shared.delegate as? AppDelegate,
                   let fcmToken = appDelegate.fcmToken {
                    updateDeviceToken(fcmToken, forceEnabled: false)
                }
            }
        } else {
            // Rule: Always add debug logs
            print("📱 [NotificationManager] System status matches app state. No change needed.")
        }
        
        return isAuthorized
    }
    
    // MARK: - Persistence
    func saveNotificationStatus() {
        UserDefaults.standard.set(isNotificationsEnabled, forKey: "notificationsEnabled")
    }
    
    // Make this method public so it can be called from AppDelegate
    func saveUnreadNotificationCount() {
        UserDefaults.standard.set(unreadNotificationCount, forKey: "unreadNotificationCount")
    }
    
    private func loadNotificationStatus() {
        // Remove loading the explicitlyDisabledByUser flag
        isNotificationsEnabled = UserDefaults.standard.bool(forKey: "notificationsEnabled")
    }
    
    private func loadUnreadNotificationCount() {
        unreadNotificationCount = UserDefaults.standard.integer(forKey: "unreadNotificationCount")
    }
    
    // MARK: - Diagnostic Functions
    func verifyDeviceTokenAndBadgeCount() {
        print("📊 [Badge Diagnostic] Starting device token and badge count verification")
        
        // Check if we have a user ID
        guard let userId = UserStatusManager.shared.state.userId else {
            print("📊 [Badge Diagnostic] No user ID available")
            return
        }
        print("📊 [Badge Diagnostic] User ID: \(userId)")
        
        // Check if we have a token directly
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            if let token = appDelegate.fcmToken {
                print("📊 [Badge Diagnostic] FCM token from AppDelegate: \(token.prefix(15))...")
            } else {
                print("📊 [Badge Diagnostic] No FCM token stored in AppDelegate")
            }
        }
        
        // Check for token via Messaging
        if let token = Messaging.messaging().fcmToken {
            print("📊 [Badge Diagnostic] FCM token from Messaging: \(token.prefix(15))...")
        } else {
            print("📊 [Badge Diagnostic] No FCM token available from Messaging")
        }
        
        // Verify badge counts
        print("📊 [Badge Diagnostic] Local badge count: \(unreadNotificationCount)")
        print("📊 [Badge Diagnostic] System badge count: \(UIApplication.shared.applicationIconBadgeNumber)")
        
        // Check Firestore for all device tokens
        db.collection("users").document(userId).collection("devices").getDocuments { (snapshot, error) in
            if let error = error {
                print("📊 [Badge Diagnostic] Error fetching devices: \(error.localizedDescription)")
                return
            }
            
            guard let documents = snapshot?.documents else {
                print("📊 [Badge Diagnostic] No devices found in Firestore")
                return
            }
            
            print("📊 [Badge Diagnostic] Found \(documents.count) devices in Firestore")
            
            for (index, document) in documents.enumerated() {
                let data = document.data()
                let tokenId = document.documentID
                let badgeCount = data["badgeCount"] as? Int ?? -1
                let enabled = data["notificationsEnabled"] as? Bool ?? false
                let lastUpdated = data["lastUpdated"] as? Timestamp
                
                print("📊 [Badge Diagnostic] Device \(index+1):")
                print("📊 [Badge Diagnostic] - Token ID: \(tokenId.prefix(15))...")
                print("📊 [Badge Diagnostic] - Badge Count: \(badgeCount)")
                print("📊 [Badge Diagnostic] - Notifications Enabled: \(enabled)")
                if let lastUpdated = lastUpdated {
                    print("📊 [Badge Diagnostic] - Last Updated: \(lastUpdated.dateValue())")
                } else {
                    print("�� [Badge Diagnostic] - Last Updated: Unknown")
                }
                
                // Check if we have a matching token in the AppDelegate
                if let appDelegate = UIApplication.shared.delegate as? AppDelegate,
                   let appToken = appDelegate.fcmToken,
                   appToken == tokenId {
                    print("📊 [Badge Diagnostic] ✅ This device matches current FCM token!")
                }
            }
        }
    }
} 