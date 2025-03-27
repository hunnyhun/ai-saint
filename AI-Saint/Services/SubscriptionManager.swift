import Foundation
import RevenueCat
import FirebaseAnalytics
import SwiftUI

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
        // Configure RevenueCat with your API key
        Purchases.configure(withAPIKey: "appl_WCSsEAgrWXsVeINtelhrPJJuklb")
        Purchases.shared.delegate = self
        
        print("DEBUG: RevenueCat configured")
        
        // Get current subscription status
        Task {
            await refreshSubscriptionStatus()
        }
    }
    
    // MARK: - Subscription Methods
    
    /// Refresh the current subscription status
    @MainActor
    func refreshSubscriptionStatus() async {
        do {
            print("DEBUG: [SubscriptionManager] Starting subscription refresh")
            
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
            
            // First get current customer info for comparison
            let beforeInfo = try await Purchases.shared.customerInfo()
            print("DEBUG: [SubscriptionManager] Before restore - Entitlements: \(beforeInfo.entitlements.all)")
            
            // Perform restore
            let customerInfo = try await Purchases.shared.restorePurchases()
            print("DEBUG: [SubscriptionManager] After restore - Entitlements: \(customerInfo.entitlements.all)")
            
            // Check if restore was successful by looking for active entitlements
            if let monthlyPremium = customerInfo.entitlements["Monthly Premium"] {
                print("DEBUG: [SubscriptionManager] Monthly Premium entitlement found:")
                print("  - isActive: \(monthlyPremium.isActive)")
                print("  - Latest purchase date: \(String(describing: monthlyPremium.latestPurchaseDate))")
                print("  - Expiration date: \(String(describing: monthlyPremium.expirationDate))")
                print("  - Store: \(String(describing: monthlyPremium.store))")
                print("  - Is sandbox: \(String(describing: monthlyPremium.isSandbox))")
            } else {
                print("DEBUG: [SubscriptionManager] No Monthly Premium entitlement found")
            }
            
            // Update subscription status
            let isPremium = customerInfo.entitlements["Monthly Premium"]?.isActive == true
            currentSubscription = isPremium ? .premium : .free
            
            print("DEBUG: [SubscriptionManager] Restore completed - Current subscription: \(currentSubscription.rawValue)")
            
            // Notify UserStatusManager to update its state
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
        
        var errorDescription: String? {
            switch self {
            case .noOfferings:
                return "No subscription offerings available"
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
