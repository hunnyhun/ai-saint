import Foundation

// MARK: - Message Type
enum MessageType {
    case user
    case ai
}

// MARK: - Chat Message
struct ChatMessage: Identifiable, Codable {
    let id: String
    let text: String
    let isUser: Bool
    let timestamp: Date
    
    // Debug helper
    var debugDescription: String {
        "Message(id: \(id), isUser: \(isUser), text: \(text))"
    }
    
    // MARK: - Equatable Implementation
    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        // Debug: Comparing ChatMessage objects
        print("Comparing messages - LHS id: \(lhs.id), RHS id: \(rhs.id)")
        return lhs.id == rhs.id &&
               lhs.text == rhs.text &&
               lhs.isUser == rhs.isUser &&
               lhs.timestamp == rhs.timestamp
    }
    
    // MARK: - Initialization
    init(id: String = UUID().uuidString, text: String, isUser: Bool, timestamp: Date) {
        self.id = id
        self.text = text
        self.isUser = isUser
        self.timestamp = timestamp
    }
}

// MARK: - Chat History
struct ChatHistory: Identifiable, Codable {
    let id: String
    let title: String
    let lastMessage: String
    let timestamp: Date
    let messages: [ChatMessage]
    
    // Debug helper
    var debugDescription: String {
        "ChatHistory(id: \(id), title: \(title), messageCount: \(messages.count))"
    }
} 
