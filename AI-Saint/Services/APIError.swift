import Foundation

// MARK: - API Error Types
enum APIError: Error, LocalizedError {
    case notAuthenticated
    case userNotFound
    case invalidResponse
    case serverError(Int)
    case tokenRefreshFailed
    case invalidData
    case serverUnavailable
    case networkError(Error)
    
    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated. Please sign in."
        case .userNotFound:
            return "User not found."
        case .invalidResponse:
            return "Invalid response from server."
        case .serverError(let code):
            return "Server error (\(code))."
        case .tokenRefreshFailed:
            return "Failed to refresh authentication token."
        case .invalidData:
            return "Invalid data received from server."
        case .serverUnavailable:
            return "Server is currently unavailable."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}

// MARK: - API Response Types (for backward compatibility)
struct ChatResponse: Codable {
    let response: String
    let conversationId: String?
} 