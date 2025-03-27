import Foundation
import FirebaseAuth

// API Service for backend communication
@Observable class APIService {
    // MARK: - Properties
    private let baseURL = "https://ai-saint-backend-647533876699.us-central1.run.app"
    private var authToken: String?
    private var tokenRefreshInProgress = false
    private var lastTokenRefresh: Date = .distantPast
    private var authStateListener: AuthStateDidChangeListenerHandle?
    
    // MARK: - Init
    init() {
        setupAuthListener()
    }
    
    deinit {
        if let listener = authStateListener {
            Auth.auth().removeStateDidChangeListener(listener)
        }
    }
    
    // MARK: - Auth Setup
    private func setupAuthListener() {
        authStateListener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task {
                if let user = user {
                    do {
                        let token = try await user.getIDToken(forcingRefresh: true)
                        self?.authToken = token
                        self?.lastTokenRefresh = Date()
                    } catch {
                        self?.authToken = nil
                        self?.lastTokenRefresh = .distantPast
                    }
                } else {
                    self?.authToken = nil
                    self?.lastTokenRefresh = .distantPast
                }
            }
        }
    }
    
    // MARK: - Token Management
    private func refreshTokenIfNeeded() async throws -> String? {
        guard let currentUser = Auth.auth().currentUser else {
            return nil
        }
        
        let tokenAge = Date().timeIntervalSince(lastTokenRefresh)
        if authToken != nil && tokenAge < 1800 { // 30 minutes
            return authToken
        }
        
        if tokenRefreshInProgress {
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            if authToken != nil {
                return authToken
            }
        }
        
        tokenRefreshInProgress = true
        defer { tokenRefreshInProgress = false }
        
        do {
            let token = try await currentUser.getIDToken(forcingRefresh: true)
            
            let tokenParts = token.components(separatedBy: ".")
            guard tokenParts.count == 3 else {
                throw APIError.tokenRefreshFailed
            }
            
            authToken = token
            lastTokenRefresh = Date()
            return token
            
        } catch {
            if let nsError = error as NSError?, nsError.code == 17011 {
                Task {
                    do {
                        try await Auth.auth().signOut()
                    } catch {
                        // Ignore signout errors
                    }
                }
                return nil
            }
            throw APIError.tokenRefreshFailed
        }
    }
    
    // MARK: - API Methods
    func sendChatMessage(_ message: String, conversationId: String? = nil) async throws -> ChatResponse {
        let token = try await refreshTokenIfNeeded()
        
        let url = URL(string: "\(baseURL)/chat/message")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        var body: [String: Any] = ["message": message]
        if let conversationId = conversationId {
            body["conversationId"] = conversationId
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            
            if httpResponse.statusCode == 401 {
                authToken = nil
                lastTokenRefresh = .distantPast
                
                if let newToken = try await refreshTokenIfNeeded() {
                    var retryRequest = request
                    retryRequest.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                    
                    let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)
                    
                    guard let retryHttpResponse = retryResponse as? HTTPURLResponse else {
                        throw APIError.invalidResponse
                    }
                    
                    if retryHttpResponse.statusCode == 401 {
                        Task {
                            do {
                                try await Auth.auth().signOut()
                            } catch {
                                // Ignore signout errors
                            }
                        }
                        throw APIError.notAuthenticated
                    }
                    
                    guard retryHttpResponse.statusCode == 200 else {
                        throw APIError.serverError(retryHttpResponse.statusCode)
                    }
                    
                    return try JSONDecoder().decode(ChatResponse.self, from: retryData)
                } else {
                    throw APIError.notAuthenticated
                }
            }
            
            guard httpResponse.statusCode == 200 else {
                throw APIError.serverError(httpResponse.statusCode)
            }
            
            return try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.serverError(500)
        }
    }

    func getChatHistory() async throws -> [ChatHistory] {
        guard let token = try await refreshTokenIfNeeded() else {
            print("ERROR: [API] No valid token for chat history request")
            throw APIError.notAuthenticated
        }
        
        let url = URL(string: "\(baseURL)/chat/history")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        print("DEBUG: [API] Fetching chat history")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("ERROR: [API] Invalid response type for chat history")
                throw APIError.invalidResponse
            }
            
            print("DEBUG: [API] Chat history response status: \(httpResponse.statusCode)")
            
            if httpResponse.statusCode != 200 {
                print("ERROR: [API] Chat history request failed with status: \(httpResponse.statusCode)")
                if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    print("ERROR: [API] Server error details:", errorJson)
                }
                throw APIError.serverError(httpResponse.statusCode)
            }
            
            // Print the raw JSON for debugging
            if let jsonString = String(data: data, encoding: .utf8) {
                print("DEBUG: [API] Raw chat history JSON:", jsonString.prefix(200), "...")
            }
            
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let dateString = try container.decode(String.self)
                
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                
                if let date = formatter.date(from: dateString) {
                    return date
                }
                
                formatter.formatOptions = [.withInternetDateTime]
                if let date = formatter.date(from: dateString) {
                    return date
                }
                
                formatter.formatOptions = [.withInternetDateTime, .withTimeZone]
                if let date = formatter.date(from: dateString) {
                    return date
                }
                
                print("ERROR: [API] Failed to decode date: \(dateString)")
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format")
            }
            
            // Try to decode as direct array first
            do {
                let history = try decoder.decode([ChatHistory].self, from: data)
                print("DEBUG: [API] Successfully decoded chat history array with \(history.count) conversations")
                return history
            } catch {
                print("DEBUG: [API] Failed to decode as array, trying as wrapped object: \(error)")
                
                // If that fails, try as wrapped object
                let historyResponse = try decoder.decode(ChatHistoryResponse.self, from: data)
                print("DEBUG: [API] Successfully decoded chat history wrapper with \(historyResponse.history.count) conversations")
                return historyResponse.history
            }
        } catch let error as APIError {
            print("ERROR: [API] Chat history API error:", error)
            throw error
        } catch let error as DecodingError {
            print("ERROR: [API] Chat history decoding error:", error)
            throw APIError.invalidData
        } catch {
            print("ERROR: [API] Unexpected error in chat history:", error)
            throw APIError.serverError(500)
        }
    }

    func post(endpoint: String, body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: "\(baseURL)\(endpoint)") else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            throw APIError.serverError(httpResponse.statusCode)
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.invalidData
        }
        
        return json
    }
}

// MARK: - Models
struct ChatResponse: Codable {
    let message: String
    let role: String
    let response: String
    let conversationId: String?
}

struct ChatHistoryResponse: Codable {
    let history: [ChatHistory]
}

// MARK: - Errors
enum APIError: Error {
    case invalidURL
    case invalidResponse
    case invalidData
    case serverError(Int)
    case notAuthenticated
    case tokenRefreshFailed
    
    var localizedDescription: String {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .invalidData:
            return "Invalid data format"
        case .serverError(let statusCode):
            return "Server error with status code: \(statusCode)"
        case .notAuthenticated:
            return "Not authenticated"
        case .tokenRefreshFailed:
            return "Failed to refresh authentication token"
        }
    }
} 