import SwiftUI

struct SidebarView: View {
    // MARK: - Properties
    let userStatusManager = UserStatusManager.shared
    @Binding var showAuthView: Bool
    @Binding var selectedFeature: Models.Feature?
    let chatViewModel: ChatViewModel
    @State private var showPaywall = false
    @State private var showAccountMenu = false
    @State private var showSettings = false
    
    // MARK: - Computed Properties
    // Fix filter predicate errors by using non-closure approach
    private var todayChats: [ChatHistory] {
        // Use manual filtering since Swift 6 has issues with filter closures in certain contexts
        var result: [ChatHistory] = []
        for chat in chatViewModel.chatHistory {
            // Use timestamp instead of lastUpdate to match ChatHistory model property
            if Calendar.current.isDateInToday(chat.timestamp) {
                result.append(chat)
            }
        }
        // Sort by timestamp descending (newest first)
        return result.sorted { $0.timestamp > $1.timestamp }
    }
    
    private var yesterdayChats: [ChatHistory] {
        // Use manual filtering since Swift 6 has issues with filter closures in certain contexts
        var result: [ChatHistory] = []
        for chat in chatViewModel.chatHistory {
            // Use timestamp instead of lastUpdate to match ChatHistory model property
            if Calendar.current.isDateInYesterday(chat.timestamp) {
                result.append(chat)
            }
        }
        // Sort by timestamp descending (newest first)
        return result.sorted { $0.timestamp > $1.timestamp }
    }
    
    private var lastWeekChats: [ChatHistory] {
        // Use manual filtering since Swift 6 has issues with filter closures in certain contexts
        var result: [ChatHistory] = []
        let calendar = Calendar.current
        let now = Date()
        
        for chat in chatViewModel.chatHistory {
            // Check if date is within last week but not today or yesterday
            if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) {
                let isInLastWeek = !calendar.isDateInToday(chat.timestamp) && 
                                  !calendar.isDateInYesterday(chat.timestamp) &&
                                  chat.timestamp >= weekAgo && 
                                  chat.timestamp <= now
                
                if isInLastWeek {
                    result.append(chat)
                }
            }
        }
        print("DEBUG: Found \(result.count) chats from last week")
        // Sort by timestamp descending (newest first)
        return result.sorted { $0.timestamp > $1.timestamp }
    }
    
    private var olderChats: [ChatHistory] {
        // Use manual filtering since Swift 6 has issues with filter closures in certain contexts
        var result: [ChatHistory] = []
        let calendar = Calendar.current
        let now = Date()
        
        for chat in chatViewModel.chatHistory {
            // Check if date is older than a week
            if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) {
                if !calendar.isDateInToday(chat.timestamp) && 
                   !calendar.isDateInYesterday(chat.timestamp) &&
                   chat.timestamp < weekAgo {
                    result.append(chat)
                }
            }
        }
        // Sort by timestamp descending (newest first)
        return result.sorted { $0.timestamp > $1.timestamp }
    }
    
    // MARK: - Body
    var body: some View {
        VStack(spacing: 0) {
            // Premium Banner - keep as requested
            if !userStatusManager.state.isPremium {
                Button(action: {
                    print("DEBUG: Opening paywall")
                    showPaywall = true
                }) {
                    HStack {
                        Image(systemName: "star.circle.fill")
                            .foregroundColor(.yellow)
                        Text("Upgrade to Premium")
                            .bold()
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.gray)
                    }
                    .foregroundColor(.primary)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)
                    .padding(.horizontal)
                }
                .padding(.top, 8)
            }
            
            // Chat history section with headers like ChatGPT
            VStack(spacing: 0) {
                // Chat history list
                ScrollView {
                    LazyVStack(spacing: 8, pinnedViews: [.sectionHeaders]) {
                        if chatViewModel.isLoadingHistory && chatViewModel.chatHistory.isEmpty {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .padding()
                        } else if chatViewModel.chatHistory.isEmpty {
                            Text("No chats yet")
                                .foregroundColor(.gray)
                                .padding()
                        } else {
                            // Show today's chats
                            Section(header: sectionHeader(title: "Today")) {
                                ForEach(todayChats) { history in
                                    chatHistoryRow(history: history)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            
                            // Yesterday section if there are chats
                            if !yesterdayChats.isEmpty {
                                Section(header: sectionHeader(title: "Yesterday")) {
                                    ForEach(yesterdayChats) { history in
                                        chatHistoryRow(history: history)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            
                            // Last Week section
                            if !lastWeekChats.isEmpty {
                                Section(header: sectionHeader(title: "Last Week")) {
                                    ForEach(lastWeekChats) { history in
                                        chatHistoryRow(history: history)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            
                            // Earlier chats
                            if !olderChats.isEmpty {
                                Section(header: sectionHeader(title: "Earlier")) {
                                    ForEach(olderChats) { history in
                                        chatHistoryRow(history: history)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .frame(maxHeight: .infinity)
            
            Divider()
            
            // User profile at bottom
            HStack(spacing: 12) {
                // User Info
                if userStatusManager.state.isAuthenticated {
                    HStack {
                        // User avatar
                        ZStack {
                            Circle()
                                .fill(Color.blue.opacity(0.2))
                                .frame(width: 36, height: 36)
                            
                            Text(userInitials)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.blue)
                        }
                        
                        // User name/email display
                        if let email = userStatusManager.state.userEmail {
                            Text(email.split(separator: "@").first ?? "")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                        }
                    }
                    
                    Spacer()
                    
                    // Settings dots
                    Button(action: {
                        showSettings = true
                    }) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 20))
                            .foregroundColor(.gray)
                            .padding(8)
                    }
                } else {
                    Button(action: { showAuthView = true }) {
                        HStack {
                            Image(systemName: "person.fill.badge.plus")
                                .font(.title3)
                            Text("Sign In")
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                        .foregroundColor(.blue)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(Color(.systemBackground))
        }
        .background(Color(.systemBackground))
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(showPaywall: $showPaywall)
        }
    }
    
    // MARK: - Helper Views and Methods
    
    // Section header for consistent styling
    private func sectionHeader(title: String) -> some View {
        Text(title)
            .font(.subheadline)
            .foregroundColor(.gray)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 20)
            .padding(.bottom, 8)
            .background(Color(.systemBackground))
    }
    
    // Get user initials for avatar
    private var userInitials: String {
        guard let email = userStatusManager.state.userEmail,
              let firstPart = email.split(separator: "@").first else {
            return "U"
        }
        
        let components = firstPart.split(separator: ".")
        if components.count > 1 {
            let first = components[0].prefix(1)
            let second = components[1].prefix(1)
            return "\(first)\(second)".uppercased()
        } else {
            return String(firstPart.prefix(2)).uppercased()
        }
    }
    
    // Chat history row
    private func chatHistoryRow(history: ChatHistory) -> some View {
        Button(action: {
            print("DEBUG: Loading conversation: \(history.id)")
            chatViewModel.loadConversation(history)
            selectedFeature = .chat
        }) {
            HStack(alignment: .center, spacing: 12) {
                // Small red traditional cross instead of chat icon
                TraditionalCross(
                    width: 10,
                    color: Color.red,
                    shadowColor: .clear
                )
                .frame(width: 16, height: 16)
                
                // Chat title and preview
                VStack(alignment: .leading, spacing: 2) {
                    // Title
                    Text(history.title)
                        .lineLimit(1)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    
                    // Last message preview
                    Text(history.lastMessage)
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                
                Spacer(minLength: 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(chatViewModel.currentConversation?.id == history.id ? 
                          Color.blue.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

#Preview {
    NavigationStack {
        SidebarView(
            showAuthView: .constant(false),
            selectedFeature: .constant(.chat),
            chatViewModel: ChatViewModel()
        )
    }
} 