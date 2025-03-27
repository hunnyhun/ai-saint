import Foundation
import SwiftUI

// MARK: - Models Module
public enum Models {
    // MARK: - App Features
    public enum Feature: Hashable {
        case chat
    }
    
    // MARK: - Auth Status
    public enum AuthStatus: String {
        case unauthenticated
        case authenticated
        
        public var displayText: String { rawValue }
    }
    
    // MARK: - Subscription Tier
    public enum SubscriptionTier: String {
        case free
        case premium
        
        public var displayText: String { rawValue }
    }
    
    // MARK: - User State
    @Observable public final class UserState {
        public var authStatus: AuthStatus = .unauthenticated
        public var subscriptionTier: SubscriptionTier = .free
        public var userEmail: String?
        public var userId: String?
        public var lastUpdated: Date = Date()
        
        public var isAuthenticated: Bool {
            authStatus == .authenticated
        }
        
        public var isPremium: Bool {
            subscriptionTier == .premium
        }
        
        public init() {}
    }
} 
