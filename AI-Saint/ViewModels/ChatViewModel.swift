import Foundation
import RevenueCat

@Observable class ChatViewModel {
    // MARK: - Properties
    private let apiService: APIService
    var messages: [ChatMessage] = []
    var chatHistory: [ChatHistory] = []
    var isLoading = false
    var isLoadingHistory = false
    var error: String?
    let userStatusManager = UserStatusManager.shared
    var currentConversation: ChatHistory?
    private var hasUnsavedChanges = false
    private var refreshTask: Task<Void, Never>?
    private var conversationSaveTask: Task<Void, Never>?
    private var currentConversationId: String
    
    // MARK: - Init
    init(apiService: APIService = APIService()) {
        self.apiService = apiService
        
        // Generate initial conversation ID with timestamp for better uniqueness
        let timestamp = ISO8601DateFormatter().string(from: Date())
        self.currentConversationId = "\(timestamp)-\(UUID().uuidString.prefix(8))"
        
        print("[Chat] ViewModel initialized with conversation ID: \(currentConversationId)")
    }
    
    deinit {
        refreshTask?.cancel()
        conversationSaveTask?.cancel()
        print("[Chat] ViewModel deinitialized")
    }
    
    // MARK: - Chat History Management
    func loadChatHistory() {
        // Cancel any existing refresh task
        refreshTask?.cancel()
        
        print("[Chat] Loading chat history")
        refreshTask = Task {
            do {
                // Show loading state immediately
                await MainActor.run {
                    self.isLoadingHistory = true
                    self.error = nil
                }
                
                // Load history in background for all users (not just premium)
                let history = try await apiService.getChatHistory()
                print("[Chat] Received history: \(history.count) conversations")
                
                // Check if task was cancelled
                if Task.isCancelled { return }
                
                await MainActor.run {
                    self.isLoadingHistory = false
                    self.chatHistory = history
                    print("[Chat] Updated chat history count:", history.count)
                    
                    // Try to match current messages with a conversation if needed
                    matchCurrentMessagesToConversation(history)
                    
                    // Cache the history for faster subsequent loads
                    Task {
                        await cacheHistory(history)
                    }
                }
                print("[Chat] Successfully loaded \(history.count) chat histories")
            } catch let apiError as APIError {
                print("[Chat] API Error loading chat history:", apiError)
                if !Task.isCancelled {
                    await MainActor.run {
                        self.isLoadingHistory = false
                        switch apiError {
                        case .notAuthenticated:
                            self.error = "Please sign in to view chat history"
                        case .serverError(let code):
                            self.error = "Server error (\(code)): Failed to load chat history"
                        case .invalidData:
                            self.error = "Invalid data received from server"
                        default:
                            self.error = "Failed to load chat history: \(apiError.localizedDescription)"
                        }
                    }
                }
            } catch {
                print("[Chat] Unexpected error loading chat history:", error)
                if !Task.isCancelled {
                    await MainActor.run {
                        self.isLoadingHistory = false
                        self.error = "An unexpected error occurred: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
    
    // Cache history for faster loading
    private func cacheHistory(_ history: [ChatHistory]) async {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(history)
            UserDefaults.standard.set(data, forKey: "cached_chat_history")
            print("[Chat] Successfully cached chat history")
        } catch {
            print("[Chat] Failed to cache chat history:", error)
        }
    }
    
    // Load cached history
    private func loadCachedHistory() -> [ChatHistory]? {
        guard let data = UserDefaults.standard.data(forKey: "cached_chat_history") else {
            return nil
        }
        
        do {
            let decoder = JSONDecoder()
            let history = try decoder.decode([ChatHistory].self, from: data)
            print("[Chat] Successfully loaded cached chat history")
            return history
        } catch {
            print("[Chat] Failed to load cached chat history:", error)
            return nil
        }
    }
    
    // Subscribe to subscription changes
    private func setupSubscriptionObserver() {
        print("DEBUG: [Chat] Setting up user state observer")
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleUserStateChange),
            name: Notification.Name("UserStateChanged"),
            object: nil
        )
    }
    
    @objc private func handleUserStateChange(_ notification: Notification) {
        guard let authStatus = notification.userInfo?["authStatus"] as? String,
              let isPremium = notification.userInfo?["isPremium"] as? Bool,
              let timestamp = notification.userInfo?["timestamp"] as? Date,
              let userId = notification.userInfo?["userId"] as? String?,
              let userEmail = notification.userInfo?["userEmail"] as? String? else {
            print("ERROR: [Chat] Invalid user state change notification data")
            return
        }
        
        print("DEBUG: [Chat] User state changed:")
        print("  - Auth Status: \(authStatus)")
        print("  - Is Premium: \(isPremium)")
        print("  - User ID: \(userId ?? "nil")")
        print("  - User Email: \(userEmail ?? "nil")")
        print("  - Timestamp: \(timestamp)")
        
        // Load chat history for all authenticated users (not just premium)
        if authStatus == "authenticated" {
            print("[Chat] User authenticated, loading chat history")
            loadChatHistory()
        } else {
            print("[Chat] User not authenticated")
            // Clear data
            messages = []
            chatHistory = []
        }
    }
    
    private func matchCurrentMessagesToConversation(_ history: [ChatHistory]) {
        // Only try to match if we have messages but no current conversation
        if currentConversation == nil && !messages.isEmpty && !history.isEmpty {
            print("[Chat] Attempting to find matching conversation for current messages")
            
            // Get the most recent conversation
            if let mostRecent = history.first {
                print("[Chat] Found most recent conversation: \(mostRecent.id)")
                
                // Check if the messages match what we have
                if mostRecent.messages.count >= messages.count {
                    // Check if the last few messages match
                    let recentMessages = Array(mostRecent.messages.suffix(messages.count))
                    let messagesMatch = zip(recentMessages, messages).allSatisfy { recent, current in
                        recent.text == current.text && recent.isUser == current.isUser
                    }
                    
                    if messagesMatch {
                        print("[Chat] Messages match, setting current conversation to: \(mostRecent.id)")
                        currentConversation = mostRecent
                        // Also update the conversation ID to match
                        currentConversationId = mostRecent.id
                    } else {
                        print("[Chat] Messages don't match with most recent conversation")
                    }
                } else {
                    print("[Chat] Most recent conversation has fewer messages than current chat")
                }
            }
        }
    }
    
    // MARK: - Conversation Management
    func loadConversation(_ conversation: ChatHistory) {
        print("[Chat] Loading conversation:", conversation.debugDescription)
        
        // If we're already viewing this conversation, do nothing
        if let current = currentConversation, current.id == conversation.id {
            print("[Chat] Already viewing this conversation, no change needed")
            return
        }
        
        // First save current conversation if needed
        if hasUnsavedChanges && messages.count > 0 {
            print("[Chat] Saving current conversation before loading new one")
            saveCurrentConversation()
        }
        
        // Then load the selected conversation
        messages = conversation.messages
        currentConversation = conversation
        currentConversationId = conversation.id
        hasUnsavedChanges = false
        error = nil
        
        print("[Chat] Loaded conversation with \(conversation.messages.count) messages, ID: \(currentConversationId)")
    }
    
    func startNewChat() {
        // First save the current conversation in case there are unsaved changes
        saveCurrentConversation()
        
        // Generate a new conversation ID with timestamp for better uniqueness
        let timestamp = ISO8601DateFormatter().string(from: Date())
        currentConversationId = "\(timestamp)-\(UUID().uuidString.prefix(8))"
        
        // Clear current state
        messages = []
        currentConversation = nil
        hasUnsavedChanges = false
        error = nil
        
        print("[Chat] New chat started with ID: \(currentConversationId)")
        
        // Force refresh chat history to ensure we have the latest conversations
        // Do this for all users, not just premium
        Task {
            // Small delay to ensure any pending saves complete
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds
            if !Task.isCancelled {
                await MainActor.run {
                    loadChatHistory()
                }
            }
        }
    }
    
    private func saveCurrentConversation() {
        guard messages.count > 0 else {
            print("[Chat] No messages to save")
            return
        }
        
        // Cancel any existing save task
        conversationSaveTask?.cancel()
        
        print("[Chat] Saving current conversation with \(messages.count) messages, ID: \(currentConversationId)")
        
        // We need to save the last message if it hasn't been sent to the backend yet
        if hasUnsavedChanges && messages.count >= 2 {
            let lastUserMessageIndex = messages.lastIndex(where: { $0.isUser }) ?? -1
            
            if lastUserMessageIndex >= 0 && lastUserMessageIndex < messages.count - 1 {
                // There's a user message followed by an AI response, save it
                let userMessage = messages[lastUserMessageIndex]
                
                conversationSaveTask = Task {
                    do {
                        // Send the last user message to ensure it's saved
                        print("[Chat] Saving last conversation exchange for ID: \(currentConversationId)")
                        _ = try await apiService.sendChatMessage(userMessage.text, conversationId: currentConversationId)
                        
                        // Check if task was cancelled
                        if Task.isCancelled { return }
                        
                        // Now refresh chat history
                        await MainActor.run {
                            loadChatHistory()
                        }
                    } catch {
                        print("[Chat] Error saving conversation:", error)
                        if !Task.isCancelled {
                            await MainActor.run {
                                self.error = "Failed to save conversation: \(error.localizedDescription)"
                            }
                        }
                    }
                }
            }
        } else {
            // Just refresh chat history
            conversationSaveTask = Task {
                // Small delay to ensure any pending operations complete
                try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
                if !Task.isCancelled {
                    await MainActor.run {
                        loadChatHistory()
                    }
                }
            }
        }
        
        hasUnsavedChanges = false
    }
    
    // MARK: - Message Handling
    func sendMessage(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("[Chat] Attempted to send empty message, ignoring")
            return
        }
        
        // Debug log
        print("[Chat] Sending message for conversation ID: \(currentConversationId)")
        
        // Check if this is a new conversation
        let isNewConversation = currentConversation == nil
        if isNewConversation {
            print("[Chat] This is a new conversation with ID: \(currentConversationId)")
        } else {
            print("[Chat] Continuing conversation: \(currentConversation?.id ?? "unknown")")
        }
        
        // Add user message
        let userMessage = ChatMessage(
            text: text,
            isUser: true,
            timestamp: Date()
        )
        messages.append(userMessage)
        hasUnsavedChanges = true
        
        // Set loading state
        isLoading = true
        error = nil
        
        // Send to backend
        Task {
            do {
                let response = try await apiService.sendChatMessage(text, conversationId: currentConversationId)
                
                // Check if task was cancelled
                if Task.isCancelled { return }
                
                // Add AI response
                await MainActor.run {
                    let aiMessage = ChatMessage(
                        text: response.response,
                        isUser: false,
                        timestamp: Date()
                    )
                    messages.append(aiMessage)
                    isLoading = false
                    
                    // Update conversation ID if returned from backend
                    if let newConversationId = response.conversationId {
                        print("[Chat] Received conversation ID from backend: \(newConversationId)")
                        if currentConversationId != newConversationId {
                            print("[Chat] Updating conversation ID from \(currentConversationId) to \(newConversationId)")
                            currentConversationId = newConversationId
                        }
                    }
                    
                    hasUnsavedChanges = false  // Messages are now saved
                    
                    // Update chat history for all authenticated users (not just premium)
                    if userStatusManager.state.isAuthenticated {
                        print("[Chat] Refreshing chat history after message")
                        // If this was a new conversation, we need to update our current conversation
                        if isNewConversation {
                            print("[Chat] This was a new conversation, refreshing to get the new conversation ID")
                            Task {
                                // Add a small delay to ensure the backend has processed the new conversation
                                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                                if !Task.isCancelled {
                                    await MainActor.run {
                                        loadChatHistory()
                                    }
                                }
                            }
                        } else {
                            loadChatHistory()
                        }
                    }
                }
                
                print("[Chat] Received response for conversation ID: \(currentConversationId)")
            } catch {
                print("[Chat] Error:", error)
                if !Task.isCancelled {
                await MainActor.run {
                        self.isLoading = false
                        self.error = "Failed to send message: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
    
    func clearMessages() {
        // Cancel any pending tasks
        refreshTask?.cancel()
        conversationSaveTask?.cancel()
        
        // Generate a new conversation ID with timestamp for better uniqueness
        let timestamp = ISO8601DateFormatter().string(from: Date())
        currentConversationId = "\(timestamp)-\(UUID().uuidString.prefix(8))"
        
        messages.removeAll()
        currentConversation = nil
        error = nil
        hasUnsavedChanges = false
        print("[Chat] Messages cleared, new conversation ID: \(currentConversationId)")
    }
} 