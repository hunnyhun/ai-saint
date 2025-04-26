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
                await self?.updateUserState()
            }
        }
        
        // Setup RevenueCat Observer
        Purchases.shared.delegate = self
        
        // Initial state update
        Task { @MainActor in
            await refreshUserState()
        }
    }
    
    // MARK: - State Management
    @MainActor
    private func updateUserState() async {
        do {
            print("DEBUG: [UserStatusManager] Starting user state update")
            
            // Update auth state
            if let user = Auth.auth().currentUser {
                print("DEBUG: [UserStatusManager] User authenticated: \(user.uid), Anonymous: \(user.isAnonymous)")
                state.authStatus = .authenticated // Keep as authenticated
                state.isAnonymous = user.isAnonymous // Set anonymous status
                state.userEmail = user.email // Email will be nil for anonymous
                state.userId = user.uid
                
                // Update RevenueCat user ID
                do {
                    let (_, _) = try await Purchases.shared.logIn(user.uid)
                    print("DEBUG: [UserStatusManager] RevenueCat user ID updated")
                } catch {
                    print("ERROR: [UserStatusManager] Failed to update RevenueCat user ID:", error.localizedDescription)
                }
                
                // Update subscription state
                let customerInfo = try await Purchases.shared.customerInfo()
                print("DEBUG: [UserStatusManager] Current customer info:")
                print("  - Entitlements: \(customerInfo.entitlements.all)")
                print("  - Active Subscriptions: \(customerInfo.activeSubscriptions)")
                
                // Check both entitlements and active subscriptions
                let hasPremiumEntitlement = customerInfo.entitlements["Monthly Premium"]?.isActive == true
                let hasActiveSubscription = customerInfo.activeSubscriptions.contains("com.hunyhun.aisaint.premium.monthly")
                let isPremium = hasPremiumEntitlement || hasActiveSubscription
                
                let wasSubscribed = state.subscriptionTier == .premium
                
                if isPremium != wasSubscribed {
                    print("DEBUG: [UserStatusManager] Subscription state changing from \(wasSubscribed) to \(isPremium)")
                    print("DEBUG: [UserStatusManager] Premium check details:")
                    print("  - Has Premium Entitlement: \(hasPremiumEntitlement)")
                    print("  - Has Active Subscription: \(hasActiveSubscription)")
                    
                    state.subscriptionTier = isPremium ? .premium : .free
                } else {
                    print("DEBUG: [UserStatusManager] Subscription state unchanged: \(wasSubscribed)")
                }
            } else {
                print("DEBUG: [UserStatusManager] User transitioned to unauthenticated state.")
                // Set local state immediately for responsiveness
                state.authStatus = .unauthenticated
                state.isAnonymous = true 
                state.userEmail = nil
                state.userId = nil
                state.subscriptionTier = .free
                state.lastUpdated = Date() // Update timestamp here
                
                // Attempt to sign in anonymously immediately after sign out
                Task { @MainActor in
                    print("DEBUG: [UserStatusManager] Attempting immediate anonymous sign-in after logout.")
                    do {
                        try await AuthenticationManager.shared.signInAnonymously()
                        // IMPORTANT: Don't call updateUserState or post notification here.
                        // The AuthStateDidChangeListener will trigger automatically on successful anonymous login,
                        // leading to updateUserState being called again with the correct anonymous user state.
                        print("DEBUG: [UserStatusManager] Anonymous sign-in call successful (listener will update state)." )
                    } catch {
                        print("ERROR: [UserStatusManager] Failed to sign in anonymously after logout: \(error.localizedDescription)")
                        // If anonymous sign-in fails, we *do* need to notify about the unauthenticated state.
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
                    }
                }
                // Return here - DO NOT post the notification for the unauthenticated state yet.
                // Let the listener triggered by signInAnonymously handle the final state update.
                return
            }
            
            // Post notification only if user is authenticated (either fully or anonymously)
            // This part is reached when the listener fires for an authenticated state.
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
            
        } catch {
            print("ERROR: [UserStatusManager] Failed to update user state:", error.localizedDescription)
            if let rcError = error as? RevenueCat.ErrorCode {
                print("ERROR: [UserStatusManager] RevenueCat error code: \(rcError)")
            }
            errorMessage = error.localizedDescription
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
        try authManager.signOut()
    }
    
    func deleteAccount() async throws {
        // Debug log
        print("🔑 Deleting user account")
        
        
        try await cloudFunctionService.deleteAccountAndData()
        
        // Then sign out using auth manager
        try authManager.signOut()
        
        // Update local state
        await updateUserState()
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
