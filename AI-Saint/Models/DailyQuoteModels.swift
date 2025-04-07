import SwiftUI
import FirebaseFirestore
import FirebaseFunctions

// MARK: - Daily Quote Feature
extension Models {
    enum QuoteType: String, Equatable, CaseIterable {
        case scheduled = "Daily"
        case favorite = "Favorite"
        
        var iconName: String {
            switch self {
            case .scheduled: return "calendar"
            case .favorite: return "heart.fill"
            }
        }
    }
    
    struct DailyQuoteRequest: Codable {
        let userId: String?
    }
    
    struct DailyQuoteResponse: Codable {
        let quote: String
    }
}

// MARK: - Daily Quote Functions
class DailyQuoteFunctions {
    // Singleton instance
    static let shared = DailyQuoteFunctions()
    
    // Properties
    private let functions = Functions.functions()
    
    // MARK: - Save Quote to Favorites
    func saveQuoteToFavorites(quote: String) async throws {
        // Debug log
        print("🌟 [DailyQuoteFunctions] Saving quote to favorites")
        
        guard let userId = UserStatusManager.shared.state.userId else {
            throw NSError(
                domain: "DailyQuoteFunctions",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "User not authenticated"]
            )
        }
        
        // Reference to user's quotes collection
        let quoteRef = Firestore.firestore()
            .collection("users")
            .document(userId)
            .collection("dailyQuotes")
            .document()
        
        // Save quote
        try await quoteRef.setData([
            "quote": quote,
            "timestamp": FieldValue.serverTimestamp(),
            "sentVia": "favorite",
            "isFavorite": true
        ])
        
        // Debug log
        print("✅ [DailyQuoteFunctions] Quote saved to favorites")
    }
    
    // MARK: - Update Quote Favorite Status
    func updateQuoteFavoriteStatus(quoteId: String, isFavorite: Bool) async throws {
        // Debug log
        print("🌟 [DailyQuoteFunctions] Updating quote favorite status to: \(isFavorite)")
        
        guard let userId = UserStatusManager.shared.state.userId else {
            throw NSError(
                domain: "DailyQuoteFunctions",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "User not authenticated"]
            )
        }
        
        // Reference to the specific quote
        let quoteRef = Firestore.firestore()
            .collection("users")
            .document(userId)
            .collection("dailyQuotes")
            .document(quoteId)
        
        // Update favorite status
        try await quoteRef.updateData([
            "isFavorite": isFavorite
        ])
        
        // Debug log
        print("✅ [DailyQuoteFunctions] Quote favorite status updated")
    }
} 