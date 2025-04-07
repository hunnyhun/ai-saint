import Foundation

// MARK: - Message Type
enum MessageType {
    case user
    case ai
}

// MARK: - Chat Message
struct ChatMessage: Identifiable, Codable, Hashable {
    let id: String
    let text: String
    let isUser: Bool
    let timestamp: Date
    
    // Computed property for debugging
    var debugDescription: String {
        return "Message(id: \(id), isUser: \(isUser), text: \(text.prefix(20))..., timestamp: \(timestamp))"
    }
    
    // For Hashable
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    // For Equatable
    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        return lhs.id == rhs.id
    }
    
    // For JSON conversion
    func toDictionary() -> [String: Any] {
        return [
            "id": id,
            "text": text,
            "isUser": isUser,
            "timestamp": timestamp.timeIntervalSince1970
        ]
    }
}

// MARK: - Chat History
struct ChatHistory: Identifiable, Codable {
    let id: String
    let title: String
    let timestamp: Date
    let messages: [ChatMessage]
    
    // Computed property for debugging
    var debugDescription: String {
        return "ChatHistory(id: \(id), title: \(title), messages: \(messages.count))"
    }
    
    // Computed property for last message
    var lastMessage: String {
        return messages.last?.text.prefix(30).appending(messages.last?.text.count ?? 0 > 30 ? "..." : "") ?? "No messages"
    }
    
    // For JSON conversion
    func toDictionary() -> [String: Any] {
        return [
            "id": id,
            "title": title,
            "timestamp": timestamp.timeIntervalSince1970,
            "messages": messages.map { $0.toDictionary() }
        ]
    }
} 
