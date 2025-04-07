import Foundation
import RevenueCat

// Debug log
import Firebase
import FirebaseAuth

// Chat history date section for UI grouping
enum ChatHistorySection: String, CaseIterable, Identifiable {
    case today = "Today"
    case yesterday = "Yesterday"
    case lastWeek = "Last Week"
    case earlier = "Earlier"
    
    var id: String { self.rawValue }
    
    // Add a computed property to return the localized string
    var localizedTitle: String {
        // Use the rawValue as the key for localization
        return self.rawValue.localized
    }
}

// Conversation with section info
struct SectionedChatHistory {
    let section: ChatHistorySection
    var conversations: [ChatHistory]
}

@Observable final class ChatViewModel {
    // MARK: - Properties
    private let cloudService: CloudFunctionService
    var messages: [ChatMessage] = []
    var chatHistory: [ChatHistory] = []
    var sectionedHistory: [SectionedChatHistory] = []
    var isLoading = false
    var isLoadingHistory = false
    var error: String?
    let userStatusManager = UserStatusManager.shared
    var currentConversation: ChatHistory?
    private var hasUnsavedChanges = false
    private var refreshTask: Task<Void, Never>?
    private var conversationSaveTask: Task<Void, Never>?
    private var currentConversationId: String
    var isRateLimited = false
    private var lastLoadTime: Date?
    private let loadThrottleInterval: TimeInterval = 3.0 // seconds
    private var observerSetup = false
    
    // MARK: - Init
    init(cloudService: CloudFunctionService = CloudFunctionService()) {
        self.cloudService = cloudService
        
        // Generate initial conversation ID with timestamp for better uniqueness
        let timestamp = ISO8601DateFormatter().string(from: Date())
        self.currentConversationId = "\(timestamp)-\(UUID().uuidString.prefix(8))"
        
        print("[Chat] ViewModel initialized with conversation ID: \(currentConversationId)")
        
        // Set up observer for user state changes
        setupSubscriptionObserver()
    }
    
    deinit {
        refreshTask?.cancel()
        conversationSaveTask?.cancel()
    }
    
    // MARK: - Chat History Management
    func loadChatHistory() {
        // Throttle frequent calls
        if let lastTime = lastLoadTime, 
           Date().timeIntervalSince(lastTime) < loadThrottleInterval {
            return
        }
        
        // Update last load time
        lastLoadTime = Date()
        
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
                
                // Load history using cloud functions
                let historyData = try await cloudService.getChatHistory()
                
                // Parse the history data into ChatHistory objects
                var history: [ChatHistory] = []
                for historyItem in historyData {
                    if let id = historyItem["id"] as? String {
                        // Try to get messages from the response
                        if let messagesData = historyItem["messages"] as? [[String: Any]] {
                            
                            // Extract title from first user message or use default
                            let title = historyItem["title"] as? String ?? "Conversation"
                            
                            // Get timestamp - enhanced handling for Firestore timestamp formats
                            let timestamp: TimeInterval
                            
                            // Try multiple formats that might come from Firebase
                            if let ts = historyItem["timestamp"] as? TimeInterval {
                                timestamp = ts
                            } else if let ts = historyItem["timestamp"] as? Double {
                                timestamp = ts
                            } else if let lastUpdated = historyItem["lastUpdated"] as? [String: Any], 
                                  let seconds = lastUpdated["_seconds"] as? TimeInterval {
                                timestamp = seconds
                            } else if let lastUpdated = historyItem["lastUpdated"] as? [String: Any],
                                  let seconds = lastUpdated["seconds"] as? TimeInterval {
                                timestamp = seconds
                            } else if let lastUpdatedStr = historyItem["lastUpdated"] as? String,
                                  let date = ISO8601DateFormatter().date(from: lastUpdatedStr) {
                                timestamp = date.timeIntervalSince1970
                            } else {
                                // Default to current time
                                timestamp = Date().timeIntervalSince1970
                            }
                            
                            // Parse messages
                            var messages: [ChatMessage] = []
                            for messageItem in messagesData {
                                // Extract message data based on Firebase format
                                if let content = messageItem["content"] as? String,
                                   let role = messageItem["role"] as? String {
                                    
                                    // Get timestamp, defaulting to current if not available
                                    let msgTimestamp: Date
                                    if let ts = messageItem["timestamp"] as? String {
                                        msgTimestamp = ISO8601DateFormatter().date(from: ts) ?? Date()
                                    } else {
                                        msgTimestamp = Date()
                                    }
                                    
                                    // Create message with Firebase format mapping
                                    let message = ChatMessage(
                                        id: messageItem["id"] as? String ?? UUID().uuidString,
                                        text: content,
                                        isUser: role == "user",
                                        timestamp: msgTimestamp
                                    )
                                    messages.append(message)
                                }
                            }
                            
                            // Create chat history object with proper timestamp
                            if !messages.isEmpty {
                                // Create Date from timestamp
                                let date = Date(timeIntervalSince1970: timestamp)
                                
                                let chatHistory = ChatHistory(
                                    id: id,
                                    title: title,
                                    timestamp: date,
                                    messages: messages
                                )
                                history.append(chatHistory)
                            }
                        }
                    }
                }
                
                print("[Chat] Parsed \(history.count) conversations")
                
                // Check if task was cancelled
                if Task.isCancelled { return }
                
                // Create a local copy to avoid reference capture issues
                let localHistory = history
                
                // Group conversations by date sections
                let groupedHistory = createSectionedHistory(localHistory)
                
                await MainActor.run {
                    self.isLoadingHistory = false
                    self.chatHistory = localHistory
                    self.sectionedHistory = groupedHistory
                    
                    // Try to match current messages with a conversation if needed
                    matchCurrentMessagesToConversation(localHistory)
                    
                    // Cache the history for faster subsequent loads
                    Task {
                        await cacheHistory(localHistory)
                    }
                }
            } catch {
                print("[Chat] Error loading chat history: \(error.localizedDescription)")
                if !Task.isCancelled {
                    await MainActor.run {
                        self.isLoadingHistory = false
                        self.error = "Failed to load chat history: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
    
    // Group conversations by date section
    private func createSectionedHistory(_ conversations: [ChatHistory]) -> [SectionedChatHistory] {
        // Get reference dates
        let now = Date()
        
        // Create calendar with explicit timezone to avoid time shift issues
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let lastWeek = calendar.date(byAdding: .day, value: -7, to: today)!
        
        // Create empty sectioned data
        var sections: [ChatHistorySection: [ChatHistory]] = [
            .today: [],
            .yesterday: [],
            .lastWeek: [],
            .earlier: []
        ]
        
        // Categorize each conversation
        for conversation in conversations {
            let date = conversation.timestamp
            let isToday = calendar.isDateInToday(date)
            let isYesterday = calendar.isDateInYesterday(date)
            
            // Check which section this conversation belongs to
            if isToday {
                sections[.today]?.append(conversation)
            } else if isYesterday {
                sections[.yesterday]?.append(conversation)
            } else if date >= lastWeek && date < yesterday {
                sections[.lastWeek]?.append(conversation)
            } else {
                sections[.earlier]?.append(conversation)
            }
        }
        
        // Sort conversations within each section - newest first
        for section in ChatHistorySection.allCases {
            sections[section]?.sort { $0.timestamp > $1.timestamp }
        }
        
        // Convert to array format and remove empty sections
        return ChatHistorySection.allCases
            .map { section in
                SectionedChatHistory(
                    section: section,
                    conversations: sections[section] ?? []
                )
            }
            .filter { !$0.conversations.isEmpty }
    }
    
    // Update sections after adding a new conversation
    private func updateSections() {
        sectionedHistory = createSectionedHistory(chatHistory)
    }
    
    // Subscribe to subscription changes
    private func setupSubscriptionObserver() {
        // Prevent multiple registrations
        guard !observerSetup else { return }
        observerSetup = true
        
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
        
        // Load chat history for all authenticated users (not just premium)
        if authStatus == "authenticated" {
            loadChatHistory()
        } else {
            // Clear data
            messages = []
            chatHistory = []
        }
    }
    
    private func matchCurrentMessagesToConversation(_ history: [ChatHistory]) {
        // Only try to match if we have messages but no current conversation
        if currentConversation == nil && !messages.isEmpty && !history.isEmpty {
            // Get the most recent conversation
            if let mostRecent = history.first {
                // Check if the messages match what we have
                if mostRecent.messages.count >= messages.count {
                    // Check if the last few messages match
                    let recentMessages = Array(mostRecent.messages.suffix(messages.count))
                    let messagesMatch = zip(recentMessages, messages).allSatisfy { recent, current in
                        recent.text == current.text && recent.isUser == current.isUser
                    }
                    
                    if messagesMatch {
                        currentConversation = mostRecent
                        // Also update the conversation ID to match
                        currentConversationId = mostRecent.id
                    }
                }
            }
        }
    }
    
    // MARK: - Message Sending
    func sendMessage(_ text: String) async {
        // Guard against concurrent requests
        guard !isLoading else {
            return
        }
        
        // Update UI state
        isLoading = true
        setErrorMessage(nil)
        
        // Create and add user message
        let userMessage = ChatMessage(
            id: UUID().uuidString,
            text: text,
            isUser: true,
            timestamp: Date()
        )
        messages.append(userMessage)
        hasUnsavedChanges = true
        
        // Call cloud function and handle response
        do {
            // Make the API call
            let responseData = try await cloudService.sendMessage(
                message: text,
                conversationId: currentConversation?.id
            )
            
            // Handle successful response
            if let responseContent = responseData["response"] as? String, !responseContent.isEmpty {
                // Create AI message
                let aiMessage = ChatMessage(
                    id: UUID().uuidString,
                    text: responseContent,
                    isUser: false,
                    timestamp: Date()
                )
                
                // Add to conversation
                messages.append(aiMessage)
                
                // Update conversation ID if provided
                if let newConversationId = responseData["conversationId"] as? String {
                    currentConversationId = newConversationId
                }
                
                // Save updated conversation
                saveConversation()
            } else {
                // Handle empty response
                setErrorMessage("Received empty response from server")
            }
        } catch let apiError as CloudFunctionError {
            // Handle API-specific errors
            
            // Special handling for rate limiting
            if apiError.localizedDescription.contains("Message limit exceeded") {
                isRateLimited = true
                setErrorMessage("Message limit exceeded. Please upgrade to premium for unlimited messages.")
            } else {
                setErrorMessage(apiError.localizedDescription)
            }
        } catch {
            // Handle unexpected errors
            let errorMessage = error.localizedDescription
            setErrorMessage("Error: \(errorMessage)")
        }
        
        // Always reset loading state
        isLoading = false
    }
    
    // Helper method to set error message
    private func setErrorMessage(_ message: String?) {
        // FIXME: Fix error property assignment issue
        // error = message
        if let message = message {
            print("[Chat] Error: \(message)")
        }
    }
    
    // MARK: - Saving Conversation
    private func saveConversation() {
        // Cancel any pending save task
        conversationSaveTask?.cancel()
        
        // Create a new save task
        conversationSaveTask = Task {
            // Create a conversation title from first user message
            let title = generateTitle()
            
            // Create a conversation object
            let conversation = ChatHistory(
                id: currentConversationId,
                title: title,
                timestamp: Date(),
                messages: messages
            )
            
            // If we're updating an existing conversation, replace it
            if let index = chatHistory.firstIndex(where: { $0.id == currentConversationId }) {
                chatHistory[index] = conversation
            } else {
                // Otherwise add it to the beginning
                chatHistory.insert(conversation, at: 0)
            }
            
            // Set as current conversation
            currentConversation = conversation
            
            // Update sections
            updateSections()
            
            // Cache history
            await cacheHistory(chatHistory)
            
            // Reset unsaved flag
            hasUnsavedChanges = false
        }
    }
    
    // MARK: - Load Conversation
    func loadConversation(_ history: ChatHistory) {
        // Set current conversation
        currentConversation = history
        messages = history.messages
        currentConversationId = history.id
        
        // Reset state
        isLoading = false
        error = nil
        hasUnsavedChanges = false
    }
    
    // Cache history for faster loading
    private func cacheHistory(_ history: [ChatHistory]) async {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(history)
            UserDefaults.standard.set(data, forKey: "cached_chat_history")
        } catch {
            print("[Chat] Failed to cache chat history: \(error.localizedDescription)")
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
            return history
        } catch {
            print("[Chat] Failed to load cached history: \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - Helper Methods
    private func generateTitle() -> String {
        // Use the first user message to generate a title
        if let firstUserMessage = messages.first(where: { $0.isUser })?.text {
            // Limit title length and clean up
            let words = firstUserMessage.split(separator: " ")
            if words.count <= 5 {
                return firstUserMessage
            } else {
                return words.prefix(5).joined(separator: " ") + "..."
            }
        }
        
        // Fallback title - now localized
        return "newConversation".localized
    }
    
    // MARK: - Conversation Management
    func clearConversation() {
        // Reset messages
        messages = []
        
        // Generate new conversation ID
        let timestamp = ISO8601DateFormatter().string(from: Date())
        currentConversationId = "\(timestamp)-\(UUID().uuidString.prefix(8))"
        
        // Reset current conversation
        currentConversation = nil
    }
    
    // For backward compatibility
    func startNewChat() {
        clearConversation()
    }
    
    func selectConversation(_ conversation: ChatHistory) {
        // Set current conversation
        currentConversation = conversation
        currentConversationId = conversation.id
        
        // Update messages
        messages = conversation.messages
        
        // Reset state
        isLoading = false
        error = nil
        hasUnsavedChanges = false
    }
} 