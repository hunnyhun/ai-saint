import Foundation
import RevenueCat
import FirebaseAnalytics
import SwiftUI
import FirebaseAuth

// MARK: - Subscription Manager
@Observable final class SubscriptionManager: NSObject {
    // MARK: - Properties
    private(set) var currentSubscription: Models.SubscriptionTier = .free
    var isLoading: Bool = false
    var errorMessage: String?
    
    // MARK: - Singleton
    static let shared = SubscriptionManager()
    
    private override init() {
        super.init()
        print("DEBUG: SubscriptionManager initialized")
        setupRevenueCat()
    }
    
    // MARK: - Setup
    private func setupRevenueCat() {
        // Configure RevenueCat with your API key, linking to Firebase UID
        print("DEBUG: [SubscriptionManager] Setting up RevenueCat...")
        
        // Get current Firebase User ID if available
        let firebaseUserID = Auth.auth().currentUser?.uid
        if let uid = firebaseUserID {
             print("DEBUG: [SubscriptionManager] Firebase User ID found: \(uid). Configuring RevenueCat with this App User ID.")
        } else {
             print("DEBUG: [SubscriptionManager] No Firebase User ID found. Configuring RevenueCat anonymously.")
        }
        
        // Use the Configuration Builder to set the App User ID
        let builder = Configuration.Builder(withAPIKey: "appl_WCSsEAgrWXsVeINtelhrPJJuklb")
        
        if let uid = firebaseUserID {
            builder.with(appUserID: uid)
        }
        
        Purchases.configure(with: builder.build())
        Purchases.shared.delegate = self

        print("DEBUG: RevenueCat configured. Current App User ID: \(Purchases.shared.appUserID ?? "Anonymous")")

        // Get current subscription status
        Task {
            await refreshSubscriptionStatus()
        }
    }
    
    // MARK: - Subscription Methods
    
    /// Refresh the current subscription status
    @MainActor
    func refreshSubscriptionStatus() async {
        // Add login/logout handling for App User ID
        let firebaseUserID = Auth.auth().currentUser?.uid
        let currentAppUserID = Purchases.shared.appUserID

        // If Firebase user exists but RC App User ID doesn't match (or is anonymous)
        if let uid = firebaseUserID, uid != currentAppUserID {
            print("DEBUG: [SubscriptionManager] Firebase UID (\(uid)) doesn't match RC App User ID (\(currentAppUserID ?? "nil")). Logging in to RevenueCat.")
            do {
                let (customerInfo, created) = try await Purchases.shared.logIn(uid)
                print("DEBUG: [SubscriptionManager] RevenueCat login successful. New customer: \(created). Customer Info: \(customerInfo)")
            } catch {
                print("ERROR: [SubscriptionManager] RevenueCat login failed: \(error.localizedDescription)")
                // Decide how to handle login failure - maybe proceed with anonymous ID or show error
            }
        } 
        // If Firebase user is nil but RC App User ID exists
        else if firebaseUserID == nil, currentAppUserID != nil {
            print("DEBUG: [SubscriptionManager] Firebase user logged out, but RC App User ID (\(currentAppUserID ?? "nil")) exists. Logging out from RevenueCat.")
            do {
                let customerInfo = try await Purchases.shared.logOut()
                print("DEBUG: [SubscriptionManager] RevenueCat logout successful. Customer Info: \(customerInfo)")
            } catch {
                print("ERROR: [SubscriptionManager] RevenueCat logout failed: \(error.localizedDescription)")
            }
        }

        // Proceed with fetching customer info after potential login/logout
        do {
            print("DEBUG: [SubscriptionManager] Starting subscription refresh with App User ID: \(Purchases.shared.appUserID ?? "Anonymous")")

            let customerInfo = try await Purchases.shared.customerInfo()
            print("DEBUG: [SubscriptionManager] Got customer info - Entitlements: \(customerInfo.entitlements.all)")
            
            // Check active subscriptions
            let isPremium = customerInfo.entitlements["Monthly Premium"]?.isActive == true
            currentSubscription = isPremium ? .premium : .free
            
            print("DEBUG: [SubscriptionManager] Updated subscription tier: \(currentSubscription.rawValue), isPremium: \(isPremium)")
            
        } catch {
            errorMessage = error.localizedDescription
            print("ERROR: [SubscriptionManager] Failed to refresh subscription status: \(error.localizedDescription)")
        }
    }
    
    /// Get available packages
    @MainActor
    func getAvailablePackages() async throws -> [Package] {
        isLoading = true
        defer { isLoading = false }
        
        return try await withCheckedThrowingContinuation { continuation in
            print("DEBUG: Fetching available packages")
            
            Purchases.shared.getOfferings { offerings, error in
                if let error = error {
                    print("ERROR: Failed to fetch offerings: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let offerings = offerings,
                      let current = offerings.current else {
                    print("ERROR: No offerings available")
                    continuation.resume(throwing: SubscriptionError.noOfferings)
                    return
                }
                
                print("DEBUG: Successfully fetched \(current.availablePackages.count) packages")
                continuation.resume(returning: current.availablePackages)
            }
        }
    }
    
    /// Purchase a package
    @MainActor
    func purchase(package: Package) async throws {
        isLoading = true
        defer { isLoading = false }
        
        do {
            print("DEBUG: [SubscriptionManager] Starting purchase for package: \(package.identifier)")
            
            // Log package details
            print("DEBUG: [SubscriptionManager] Package details:")
            print("  - Identifier: \(package.identifier)")
            print("  - Store product ID: \(package.storeProduct.productIdentifier)")
            print("  - Price: \(package.storeProduct.price)")
            print("  - Subscription period: \(package.storeProduct.subscriptionPeriod?.unit ?? .month)")
            
            let result = try await Purchases.shared.purchase(package: package)
            
            // Log purchase result
            print("DEBUG: [SubscriptionManager] Purchase successful")
            print("DEBUG: [SubscriptionManager] Customer info after purchase:")
            print("  - Entitlements: \(result.customerInfo.entitlements.all)")
            print("  - Active Subscriptions: \(result.customerInfo.activeSubscriptions)")
            
            // Log purchase event to Firebase Analytics
            Analytics.logEvent(AnalyticsEventPurchase, parameters: [
                AnalyticsParameterItemID: package.identifier,
                AnalyticsParameterPrice: package.storeProduct.price
            ])
            
            // Update subscription status
            let hasPremiumEntitlement = result.customerInfo.entitlements["Monthly Premium"]?.isActive == true
            let hasActiveSubscription = result.customerInfo.activeSubscriptions.contains("com.hunyhun.aisaint.premium.monthly")
            let isPremium = hasPremiumEntitlement || hasActiveSubscription
            
            currentSubscription = isPremium ? .premium : .free
            
            print("DEBUG: [SubscriptionManager] Updated subscription tier: \(currentSubscription.rawValue)")
            print("DEBUG: [SubscriptionManager] Premium check details:")
            print("  - Has Premium Entitlement: \(hasPremiumEntitlement)")
            print("  - Has Active Subscription: \(hasActiveSubscription)")
            
            // Notify UserStatusManager to update its state
            await UserStatusManager.shared.refreshUserState()
            
        } catch {
            print("ERROR: [SubscriptionManager] Purchase failed: \(error.localizedDescription)")
            if let rcError = error as? RevenueCat.ErrorCode {
                print("ERROR: [SubscriptionManager] RevenueCat error code: \(rcError)")
            }
            throw error
        }
    }
    
    /// Restore purchases
    @MainActor
    func restorePurchases() async throws {
        isLoading = true
        defer { isLoading = false }
        
        do {
            print("DEBUG: [SubscriptionManager] Starting purchase restoration")
            
            // Ensure user is logged in to Firebase before restoring
            guard let firebaseUserID = Auth.auth().currentUser?.uid else {
                print("ERROR: [SubscriptionManager] User must be logged in to restore purchases.")
                // Optionally throw a specific error
                throw SubscriptionError.notLoggedIn
            }
            print("DEBUG: [SubscriptionManager] Current Firebase User ID: \(firebaseUserID)")

            // First get current customer info for comparison
            let beforeInfo = try await Purchases.shared.customerInfo()
            print("DEBUG: [SubscriptionManager] Before restore - AppUserID: \(beforeInfo.originalAppUserId), Entitlements: \(beforeInfo.entitlements.all)")

            // Perform restore
            let customerInfo = try await Purchases.shared.restorePurchases()
            print("DEBUG: [SubscriptionManager] After restore - AppUserID: \(customerInfo.originalAppUserId), Entitlements: \(customerInfo.entitlements.all)")

            // Check if restore was successful by looking for active entitlements
            let isPremiumActive = customerInfo.entitlements["Monthly Premium"]?.isActive == true
            let restoredAppUserID = customerInfo.originalAppUserId // Use originalAppUserId which should be stable
            
            print("DEBUG: [SubscriptionManager] Restore check: isPremiumActive=\(isPremiumActive), restoredAppUserID=\(restoredAppUserID ?? "nil"), currentFirebaseUID=\(firebaseUserID)")

            if isPremiumActive {
                // **CRITICAL CHECK**: Validate that the restored App User ID matches the current Firebase User ID
                if restoredAppUserID == firebaseUserID {
                    print("DEBUG: [SubscriptionManager] Restore successful and App User ID matches Firebase UID. Granting premium.")
                    currentSubscription = .premium
                } else {
                    // Mismatch detected! Do not grant premium.
                    print("WARN: [SubscriptionManager] Restore successful, but App User ID (\(restoredAppUserID ?? "nil")) does not match current Firebase UID (\(firebaseUserID)). Potential abuse attempt or account switching. Not granting premium.")
                    currentSubscription = .free // Keep user as free
                    // Optionally show an alert to the user explaining the mismatch.
                     errorMessage = "Restored purchase belongs to a different user account."
                     // You might want to throw a specific error here instead of just setting errorMessage
                     // throw SubscriptionError.restoreMismatch 
                }
            } else {
                 print("DEBUG: [SubscriptionManager] No active 'Monthly Premium' entitlement found after restore.")
                 currentSubscription = .free
            }

            print("DEBUG: [SubscriptionManager] Restore completed - Final subscription: \(currentSubscription.rawValue)")

            // Notify UserStatusManager to update its state (only if necessary)
            await UserStatusManager.shared.refreshUserState()

        } catch {
            print("ERROR: [SubscriptionManager] Restore failed with error: \(error.localizedDescription)")
            if let rcError = error as? RevenueCat.ErrorCode {
                print("ERROR: [SubscriptionManager] RevenueCat error code: \(rcError)")
            }
            throw error
        }
    }
}

// MARK: - Custom Errors
extension SubscriptionManager {
    enum SubscriptionError: LocalizedError {
        case noOfferings
        case notLoggedIn // Added error for restore attempt when not logged in
        case restoreMismatch // Added error for App User ID mismatch during restore

        var errorDescription: String? {
            switch self {
            case .noOfferings:
                return "No subscription offerings available"
            case .notLoggedIn:
                return "You must be logged in to restore purchases."
            case .restoreMismatch:
                 return "The restored purchase is linked to a different account."
            }
        }
    }
}

// MARK: - RevenueCat Delegate
extension SubscriptionManager: PurchasesDelegate {
    func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) {
        print("DEBUG: RevenueCat update received")
        Task { @MainActor in
            await refreshSubscriptionStatus()
        }
    }
}
