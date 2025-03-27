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
                print("DEBUG: [UserStatusManager] User authenticated: \(user.uid)")
                state.authStatus = .authenticated
                state.userEmail = user.email
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
                print("DEBUG: [UserStatusManager] User not authenticated")
                state.authStatus = .unauthenticated
                state.userEmail = nil
                state.userId = nil
                state.subscriptionTier = .free
            }
            
            state.lastUpdated = Date()
            
            // Post single notification for all state changes
            NotificationCenter.default.post(
                name: Notification.Name("UserStateChanged"),
                object: nil,
                userInfo: [
                    "authStatus": state.authStatus.rawValue,
                    "isPremium": state.isPremium,
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
        try await authManager.signOut()
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
