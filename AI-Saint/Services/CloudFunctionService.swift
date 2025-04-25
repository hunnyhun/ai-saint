import Foundation
import FirebaseAuth
import FirebaseFunctions

// Rule: Always add debug logs & comment in the code for easier debug and readabilty
// Rule: The fewer lines of code is better

// Custom error enum for better error handling
enum CloudFunctionError: Error {
    case notAuthenticated
    case serverError(String)
    case parseError
    case networkError(Error)
    case rateLimitExceeded(String)
    
    var localizedDescription: String {
        switch self {
        case .notAuthenticated:
            return "User not authenticated"
        case .serverError(let message):
            return "Server error: \(message)"
        case .parseError:
            return "Failed to parse server response"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .rateLimitExceeded(let message):
            return message
        }
    }
}

@Observable class CloudFunctionService {
    // Service instance
    private var functions: Functions
    
    // MARK: - Singleton
    static let shared = CloudFunctionService()
    
    init() {
        // Debug log
        print("🌩️ CloudFunctionService initialized")
        
        // Initialize Firebase Functions with region
        self.functions = Functions.functions(region: "us-central1")
        
        // Debug: Log auth state
        if let user = Auth.auth().currentUser {
            print("🌩️ User authenticated: \(user.uid)")
        } else {
            print("🌩️ No authenticated user")
        }
        
        // Add debug for available functions
        print("🌩️ Using Firebase Functions region: us-central1")
    }
    
    // MARK: - Chat History
    func getChatHistory() async throws -> [[String: Any]] {
        // Debug log
        print("🌩️ Getting chat history")
        
        do {
            // Check authentication
            guard let user = Auth.auth().currentUser else {
                print("🌩️ No authenticated user found")
                throw CloudFunctionError.notAuthenticated
            }
            
            // Debug: Log auth token
            print("🌩️ User ID: \(user.uid)")
            
            // Try to get a token for debugging
            let tokenResult = try await user.getIDTokenResult()
            print("🌩️ User has valid token: \(tokenResult.token.prefix(10))...")
            
            // Call the v2 Cloud Function - ensure exact name match
            let result = try await functions.httpsCallable("getChatHistoryV2").call()
            
            // Parse response
            guard let conversations = result.data as? [[String: Any]] else {
                print("🌩️ Failed to parse chat history response")
                throw CloudFunctionError.parseError
            }
            
            // Debug log
            print("🌩️ Successfully fetched chat history with \(conversations.count) conversations")
            return conversations
        } catch let error as CloudFunctionError {
            // Re-throw our custom errors
            print("🌩️ Error getting chat history: \(error.localizedDescription)")
            throw error
        } catch {
            // Handle all other errors
            print("🌩️ Function error detail: \(error)")
            
            // Check if it's a Firebase Functions error
            let nsError = error as NSError
            if nsError.domain == FunctionsErrorDomain { // Use FunctionsErrorDomain constant
                // Check the specific error code
                if let code = FunctionsErrorCode(rawValue: nsError.code) {
                    switch code {
                    case .resourceExhausted:
                        // Extract the message from details if possible, otherwise use default
                        let message = (nsError.userInfo[FunctionsErrorDetailsKey] as? String) ?? "Rate limit exceeded."
                        print("🌩️ Rate limit exceeded: \(message)")
                        throw CloudFunctionError.rateLimitExceeded(message)
                    default:
                        // Handle other Firebase function errors
                        print("🌩️ Firebase Functions server error: \(nsError.localizedDescription)")
                        throw CloudFunctionError.serverError(nsError.localizedDescription)
                    }
                } else {
                    // Fallback for unknown Firebase function errors
                    print("🌩️ Unknown Firebase Functions error code: \(nsError.code)")
                    throw CloudFunctionError.serverError(nsError.localizedDescription)
                }
            } else {
                // Handle non-Firebase network errors
                print("🌩️ Network error: \(error.localizedDescription)")
                throw CloudFunctionError.networkError(error)
            }
        }
    }
    
    // MARK: - Send Message
    func sendMessage(message: String, conversationId: String? = nil) async throws -> [String: Any] {
        // Debug log
        print("🌩️ Sending message: \(message)")
        
        do {
            // Check authentication
            guard let user = Auth.auth().currentUser else {
                print("🌩️ No authenticated user found")
                throw CloudFunctionError.notAuthenticated
            }
            
            // Debug: Log auth token and user info
            print("🌩️ User ID: \(user.uid)")
            
            // Try to get a token for debugging
            let tokenResult = try await user.getIDTokenResult()
            print("🌩️ User has valid token: \(tokenResult.token.prefix(10))...")
            
            // Prepare request data
            var requestData: [String: Any] = [
                "message": message
            ]
            
            // Add conversation ID if provided
            if let conversationId = conversationId {
                requestData["conversationId"] = conversationId
                print("🌩️ Using conversation ID: \(conversationId)")
            }
            
            // Debug: Log request data
            print("🌩️ Request data: \(requestData)")
            
            // Call the v2 Cloud Function - ensure exact name match
            let result = try await functions.httpsCallable("processChatMessageV2").call(requestData)
            
            // Parse response data
            guard let responseData = result.data as? [String: Any] else {
                print("🌩️ Failed to parse response")
                throw CloudFunctionError.parseError
            }
            
            // Debug log
            print("🌩️ Successfully received response: \(responseData)")
            return responseData
        } catch let error as CloudFunctionError {
            // Re-throw our custom errors
            print("🌩️ Error sending message: \(error.localizedDescription)")
            throw error
        } catch {
            // Handle all other errors - add more detailed logging
            print("🌩️ Function error detail: \(error)")
            
            // Check if it's a Firebase Functions error
            let nsError = error as NSError
            if nsError.domain == FunctionsErrorDomain { // Use FunctionsErrorDomain constant
                // Check the specific error code
                if let code = FunctionsErrorCode(rawValue: nsError.code) {
                    switch code {
                    case .resourceExhausted:
                        // Extract the message from details if possible, otherwise use default
                        let message = (nsError.userInfo[FunctionsErrorDetailsKey] as? String) ?? "Rate limit exceeded."
                        print("🌩️ Rate limit exceeded: \(message)")
                        throw CloudFunctionError.rateLimitExceeded(message)
                    // Add other specific codes if needed, e.g.:
                    // case .unauthenticated:
                    //    print("🌩️ Unauthenticated error from Functions")
                    //    throw CloudFunctionError.notAuthenticated
                    default:
                        // Handle other Firebase function errors
                        print("🌩️ Firebase Functions server error: \(nsError.localizedDescription)")
                        throw CloudFunctionError.serverError(nsError.localizedDescription)
                    }
                } else {
                    // Fallback for unknown Firebase function errors
                    print("🌩️ Unknown Firebase Functions error code: \(nsError.code)")
                    throw CloudFunctionError.serverError(nsError.localizedDescription)
                }
            } else {
                // Handle non-Firebase network errors
                print("🌩️ Network error: \(error.localizedDescription)")
                throw CloudFunctionError.networkError(error)
            }
        }
    }

    // MARK: - Delete Account
    func deleteAccountAndData() async throws {
        // Debug log
        print("🌩️ Deleting account and data")
        
        do {
            // Check authentication
            guard let user = Auth.auth().currentUser else {
                print("🌩️ No authenticated user found for deletion")
                throw CloudFunctionError.notAuthenticated
            }
            
            // Debug: Log user ID being deleted
            print("🌩️ Requesting deletion for User ID: \(user.uid)")
            
            // Try to get a token for debugging (optional, but good practice)
            let tokenResult = try await user.getIDTokenResult()
            print("🌩️ User has valid token for deletion request: \(tokenResult.token.prefix(10))...")
            
            // Call the Cloud Function - ensure exact name match
            // No parameters needed for this call
            let result = try await functions.httpsCallable("deleteAccountAndData").call()
            
            // Parse response data - expecting { success: true }
            guard let responseData = result.data as? [String: Any], responseData["success"] as? Bool == true else {
                // Check if there's an error message in the response (though the function throws HttpsError on failure)
                let message = (result.data as? [String: Any])?["message"] as? String ?? "Unknown error during deletion."
                print("🌩️ Failed to confirm successful deletion from backend: \(result.data ?? "No data")")
                throw CloudFunctionError.serverError(message)
            }
            
            // Debug log on success from cloud function
            print("🌩️ Successfully deleted account data via cloud function for user \(user.uid)")
            
        } catch let error as CloudFunctionError {
            // Re-throw our custom errors
            print("🌩️ Error deleting account: \(error.localizedDescription)")
            throw error
        } catch {
            // Handle all other errors
            print("🌩️ Function error detail during deletion: \(error)")
            
            let nsError = error as NSError
            if nsError.domain == FunctionsErrorDomain { // Check if it's a Functions error
                if let code = FunctionsErrorCode(rawValue: nsError.code) {
                    switch code {
                    case .unauthenticated:
                        print("🌩️ Unauthenticated error from Functions during deletion")
                        throw CloudFunctionError.notAuthenticated
                    // Add other specific codes if needed (e.g., internal, unavailable)
                    default:
                        let message = (nsError.userInfo[FunctionsErrorDetailsKey] as? String) ?? nsError.localizedDescription
                        print("🌩️ Firebase Functions server error during deletion: \(message)")
                        throw CloudFunctionError.serverError(message)
                    }
                } else {
                    print("🌩️ Unknown Firebase Functions error code during deletion: \(nsError.code)")
                    throw CloudFunctionError.serverError(nsError.localizedDescription)
                }
            } else {
                // Handle non-Firebase network errors
                print("🌩️ Network error during deletion: \(error.localizedDescription)")
                throw CloudFunctionError.networkError(error)
            }
        }
    }
} 