import SwiftUI
import FirebaseAuth
import RevenueCat

// MARK: - User State Model
@Observable final class UserState {
    var authStatus: AuthStatus = .unauthenticated
    var subscriptionTier: SubscriptionTier = .free
    var userEmail: String?
    var userId: String?
    var lastUpdated: Date = Date()
    var isAnonymous: Bool = true // Default to true, update on auth change
    
    var isAuthenticated: Bool {
        authStatus == .authenticated
    }
    
    var isPremium: Bool {
        subscriptionTier == .premium
    }
}

// MARK: - Auth Status
enum AuthStatus: String {
    case unauthenticated
    case authenticated
    
    var displayText: String { rawValue }
}

// MARK: - Subscription Tier
enum SubscriptionTier: String {
    case free
    case premium
    
    var displayText: String { rawValue }
}

// MARK: - App Features
enum AppFeature {
    case chat
}

// MARK: - User Status Manager
@Observable final class UserStatusManager: NSObject {
    // MARK: - Properties
    private let authManager = AuthenticationManager.shared
    private let cloudFunctionService = CloudFunctionService.shared
    private let subscriptionManager = SubscriptionManager.shared
    private(set) var state = Models.UserState()
    private var authStateListener: AuthStateDidChangeListenerHandle?
    
    var isLoading: Bool = false
    var errorMessage: String?
    
    // MARK: - Computed Properties
    var currentStatus: Models.AuthStatus {
        state.authStatus
    }
    
    var userEmail: String? {
        state.userEmail
    }
    
    // MARK: - Singleton
    static let shared = UserStatusManager()
    
    private override init() {
        super.init()
        setupObservers()
    }
    
    deinit {
        if let listener = authStateListener {
            Auth.auth().removeStateDidChangeListener(listener)
        }
    }
    
    // MARK: - Setup
    private func setupObservers() {
        // Setup Auth State Observer
        authStateListener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                // Update state whenever auth changes
                await self?.updateUserState()
            }
        }
        
        // Setup RevenueCat Observer
        Purchases.shared.delegate = self
        
        // Initial state check & potential anonymous login
        Task { @MainActor in
            if Auth.auth().currentUser == nil {
                print("DEBUG: [UserStatusManager] No current user on initial setup. Attempting persistent anonymous sign in...")
                do {
                    // Call the new method that handles Keychain ID and (eventually) custom tokens
                    try await AuthenticationManager.shared.signInAnonymously()
                    // Note: updateUserState will be triggered by the auth state listener if sign-in succeeds
                    print("DEBUG: [UserStatusManager] Persistent anonymous sign-in attempt initiated.")
                } catch {
                    print("ERROR: [UserStatusManager] Initial persistent anonymous sign-in failed: \(error.localizedDescription)")
                    // Handle error appropriately - maybe show an error message to the user?
                    self.errorMessage = "Failed to initialize session. Please restart the app."
                    // Manually ensure state reflects failure
                    await self.updateUserState() // Update state based on the failed auth attempt (should remain unauthenticated)
                }
            } else {
                 print("DEBUG: [UserStatusManager] Existing user found on initial setup: \(Auth.auth().currentUser!.uid)")
                 // Existing user found, just refresh state
            await refreshUserState()
            }
        }
    }
    
    // MARK: - State Management
    @MainActor
    private func updateUserState() async {
        // Capture the user ID *before* the state change
        let previousUserId = state.userId
        
        do {
            print("DEBUG: [UserStatusManager] Starting user state update (Previous User ID: \(previousUserId ?? "none"))")
            
            // Get the current Firebase user
            let user = Auth.auth().currentUser
            let newUserId = user?.uid // Can be nil if logged out
            
            // --- Device Token Cleanup Logic ---
            if newUserId != previousUserId, let oldUserId = previousUserId {
                // User ID changed (logout, login, link). Clean up old token.
                if let fcmToken = NotificationManager.shared.getCurrentFCMToken() { // Use helper to get token
                    print("DEBUG: [UserStatusManager] User ID changed. Attempting to remove token \(fcmToken.prefix(10))... from old user \(oldUserId)")
                    await NotificationManager.shared.removeDeviceTokenFromUser(userId: oldUserId, fcmToken: fcmToken)
                } else {
                    print("DEBUG: [UserStatusManager] User ID changed, but no FCM token found to remove.")
                }
            }
            // --- End Cleanup Logic ---
            
            // Now, update the state based on the *current* user
            if let user = user { // Use the user var we already fetched
                // Determine if the user should be treated as anonymous
                // Anonymous if providerData is empty (covers custom token users AND built-in anonymous)
                let isEffectivelyAnonymous = user.providerData.isEmpty

                print("DEBUG: [UserStatusManager] User authenticated: \(user.uid), ProviderData empty: \(isEffectivelyAnonymous), BuiltInAnonymous: \(user.isAnonymous)")
                state.authStatus = .authenticated
                state.isAnonymous = isEffectivelyAnonymous // <-- Use the new logic
                state.userEmail = user.email
                state.userId = user.uid // Set the new user ID
                
                // Update RevenueCat user ID if necessary
                if Purchases.shared.appUserID != user.uid {
                do {
                    let (_, _) = try await Purchases.shared.logIn(user.uid)
                        print("DEBUG: [UserStatusManager] RevenueCat user ID updated to \(user.uid)")
                } catch {
                        print("ERROR: [UserStatusManager] Failed to update RevenueCat user ID: \(error.localizedDescription)")
                    }
                }
                
                // Update subscription state using the unified "Premium" entitlement
                let customerInfo = try await Purchases.shared.customerInfo()
                let isPremium = customerInfo.entitlements["Premium"]?.isActive == true || 
                                !customerInfo.activeSubscriptions.isEmpty // Check for *any* active sub as backup
                let wasSubscribed = state.subscriptionTier == .premium
                state.subscriptionTier = isPremium ? .premium : .free
                if isPremium != wasSubscribed {
                     print("DEBUG: [UserStatusManager] Subscription state changed to: \(state.subscriptionTier.rawValue)")
                }
                
                // The postUserStateChangedNotification() call below should happen *after* state is fully updated for the authenticated user
                // and not conditionally within the removed anonymous sign-in task.
                postUserStateChangedNotification() // Ensure notification is sent after state update

            } else { // User is nil (logged out)
                print("DEBUG: [UserStatusManager] User transitioned to unauthenticated state.")
                // Set local state immediately
                state.authStatus = .unauthenticated
                state.isAnonymous = true 
                state.userEmail = nil
                state.userId = nil // Set userId to nil
                state.subscriptionTier = .free
                state.lastUpdated = Date()
                
                // Log out of RevenueCat if necessary when Firebase user is truly nil.
                // We check !Purchases.shared.isAnonymous because we only need to log out
                // if RevenueCat currently has a specific App User ID (not an RC-generated anonymous one).
                if !Purchases.shared.isAnonymous { // Fixed: Removed redundant '!= nil' check
                    do {
                        _ = try await Purchases.shared.logOut()
                        print("DEBUG: [UserStatusManager] Logged out from RevenueCat after user became nil.")
                    } catch {
                        // Log error, but continue, as the primary goal is anonymous sign-in attempt.
                        print("ERROR: [UserStatusManager] Failed to log out from RevenueCat after user became nil: \(error.localizedDescription)")
                    }
                }

                // Post notification to indicate the user is now fully logged out.
                postUserStateChangedNotification() 
                
                // We no longer attempt automatic anonymous sign-in here.
                // The user remains logged out until they explicitly sign in again.
                // Removed the Task that called AuthenticationManager.shared.signInAnonymously()

                // The 'return' statement below is no longer needed as we are not waiting for an async task.
                // Removed

            } // End of else block (user == nil)
            
            // Update last updated time (only for non-nil user states, due to 'return' in else block)
            state.lastUpdated = Date()
            
        } catch {
            print("ERROR: [UserStatusManager] Failed to update user state: \(error.localizedDescription)")
            if let rcError = error as? RevenueCat.ErrorCode {
                print("ERROR: [UserStatusManager] RevenueCat error code: \(rcError)")
            }
            errorMessage = error.localizedDescription
            // Consider posting notification even on error? Depends on desired UI behavior.
            // postUserStateChangedNotification() 
        }
    }
    
    @MainActor
    func refreshUserState() async {
        isLoading = true
        defer { isLoading = false }
        
        await updateUserState()
    }
    
    // MARK: - Feature Access Control
    func canAccessFeature(_ feature: Models.Feature) -> Bool {
        // All users can access chat
        return true
    }
    
    // MARK: - Auth Methods
    func signOut() async throws {
        // Debug log
        print("🔑 Signing out user")
        try await authManager.signOut()
    }
    
    func deleteAccount() async throws {
        // Debug log
        print("🔑 Deleting user account")
        
        
        try await cloudFunctionService.deleteAccountAndData()

        // Then sign out using auth manager
        try await authManager.signOut()

        // Clear the persistent anonymous user ID from Keychain (if it exists)
        do {
            try KeychainHelper.shared.deleteAnonymousId()
            print("DEBUG: [UserStatusManager] Cleared persistent anonymous ID from Keychain during account deletion.")
        } catch {
             print("ERROR: [UserStatusManager] Failed to clear persistent anonymous ID from Keychain during account deletion: \(error.localizedDescription)")
             // Log error, but continue with the rest of the deletion process
        }

        // Update local state (updateUserState will handle the post-logout state)
        // No longer need to manually trigger anonymous sign-in here.
        await updateUserState()
    }
    
    // Helper to post notification
    private func postUserStateChangedNotification() {
        NotificationCenter.default.post(
            name: Notification.Name("UserStateChanged"),
            object: nil,
            userInfo: [
                "authStatus": state.authStatus.rawValue,
                "isPremium": state.isPremium,
                "isAnonymous": state.isAnonymous,
                "timestamp": state.lastUpdated,
                "userId": state.userId as Any,
                "userEmail": state.userEmail as Any
            ]
        )
        print("DEBUG: [UserStatusManager] Posted UserStateChanged notification")
    }
}

// MARK: - RevenueCat Delegate
extension UserStatusManager: PurchasesDelegate {
    func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) {
        Task { @MainActor in
            await updateUserState()
        }
    }
} 
