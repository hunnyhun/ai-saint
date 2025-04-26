import SwiftUI

struct SidebarView: View {
    // MARK: - Properties
    let userStatusManager = UserStatusManager.shared
    let notificationManager = NotificationManager.shared
    @Binding var showAuthView: Bool
    @Binding var selectedFeature: Models.Feature?
    let chatViewModel: ChatViewModel
    @State private var showPaywall = false
    @State private var showAccountMenu = false
    @State private var showSettings = false
    @State private var showDailyQuote = false
    
    // MARK: - Body
    var body: some View {
        VStack(spacing: 0) {
            // Premium Banner - keep as requested
            if !userStatusManager.state.isPremium && !userStatusManager.state.isAnonymous {
                Button(action: {
                    print("DEBUG: Opening paywall")
                    showPaywall = true
                }) {
                    HStack {
                        Image(systemName: "star.circle.fill")
                            .foregroundColor(.yellow)
                        Text("upgradeToPremiumButton".localized)
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
            
            // Daily Quote Button
            Button(action: {
                // Clear notification count before showing view
                if notificationManager.unreadNotificationCount > 0 {
                    print("📱 [SidebarView] Clearing \(notificationManager.unreadNotificationCount) notifications")
                    notificationManager.markNotificationsAsRead()
                }
                
                // Then show the daily quote view
                print("📱 [SidebarView] Opening Daily Quote view")
                showDailyQuote = true
            }) {
                HStack {
                    Image(systemName: "quote.bubble.fill")
                        .foregroundColor(.yellow)
                    Text("dailySpiritualQuote".localized)
                        .bold()
                    Spacer()
                    
                    // Badge showing unread notification count
                    if notificationManager.unreadNotificationCount > 0 {
                        ZStack {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 22, height: 22)
                            
                            Text("\(notificationManager.unreadNotificationCount)")
                                .font(.caption2)
                                .bold()
                                .foregroundColor(.white)
                        }
                    }
                    
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
            
            // Settings Button for Anonymous Users
            if userStatusManager.state.isAnonymous {
                Button { 
                    showSettings = true
                } label: {
                     HStack {
                        Image(systemName: "gearshape.fill") // Settings icon
                            .foregroundColor(.gray)
                        Text("settingsButtonLabel".localized) // Use localized key
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
                .padding(.top, 8) // Spacing below daily quote button
            }
            
            // Chat history section with headers like ChatGPT
            VStack(spacing: 0) {
                // Chat history list
                ScrollView {
                    LazyVStack(spacing: 8, pinnedViews: [.sectionHeaders]) {
                        if userStatusManager.state.isAnonymous {
                            // Show message for anonymous users
                            Text("signInToViewHistory".localized) // Use localized key
                                .foregroundColor(.secondary)
                                .font(.footnote)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else if chatViewModel.isLoadingHistory && chatViewModel.chatHistory.isEmpty {
                            // Show loading indicator if not anonymous and loading
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .padding()
                        } else if chatViewModel.chatHistory.isEmpty {
                            // Show no chats message if not anonymous and history is empty
                            Text("noChatsYet".localized)
                                .foregroundColor(.gray)
                                .padding()
                        } else {
                            // Display sections if not anonymous and history is loaded
                            ForEach(chatViewModel.sectionedHistory, id: \.section.id) { section in
                                Section(header: sectionHeader(title: section.section.rawValue)) {
                                    ForEach(section.conversations) { history in
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
            
            // User profile at bottom
            HStack(spacing: 12) {
                // User Info or Sign In Button
                if userStatusManager.state.isAuthenticated {
                    if userStatusManager.state.isAnonymous {
                        // Anonymous User - Show Sign In Prompt
                        VStack(spacing: 8) {
                            // Promotional Text (Moved Above Button)
                            Text("signUpBenefitText".localized)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                                .padding(.bottom, 4) // Add small padding below text
                            
                            // Sign In / Sign Up Button
                            Button { 
                                showAuthView = true
                            } label: {
                                Text("signUpOrLogIn".localized) // Use localized key
                                    .font(.headline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white.opacity(0.8)) // Dark text on yellow
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 20)
                                    .frame(maxWidth: .infinity) 
                                    .background(Color.yellow.opacity(0.8)) // Golden background
                                    .cornerRadius(10)
                            }
                            .padding(.horizontal) // Padding for the button
                        }
                        .frame(maxWidth: .infinity) // Center the VStack content
                    } else {
                        // Authenticated User - Show User Info
                    HStack {
                        // User avatar
                        Circle()
                            .fill(Color.blue.opacity(0.2))
                            .frame(width: 36, height: 36)
                            .overlay(
                                Text(userStatusManager.state.userEmail?.prefix(1).uppercased() ?? "U")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.blue)
                            )
                        
                        VStack(alignment: .leading, spacing: 2) {
                            // User email text with overflow handling
                            if let email = userStatusManager.state.userEmail {
                                Text(email)
                                    .font(.footnote)
                                    .lineLimit(1)
                                    .foregroundColor(.primary)
                            }
                            
                            // Subscription tier
                            Text(userStatusManager.state.subscriptionTier.displayText.capitalized)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Spacer()
                    
                        // Settings button (only for non-anonymous users)
                    Button(action: {
                        showSettings = true
                    }) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 18))
                            .foregroundColor(.gray)
                            .padding(8)
                    }
                }
                }
                // No need for an else here, as ContentView handles initial anonymous login
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.systemBackground))
            .shadow(color: Color.black.opacity(0.1), radius: 3, x: 0, y: -2)
        }
        .background(Color(.systemBackground))
        .sheet(isPresented: $showSettings) {
            SettingsView(showPaywall: $showPaywall)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
        .sheet(isPresented: $showDailyQuote) {
            DailyQuoteView(fromNotification: false)
        }
    }
    
    // MARK: - Section Header
    private func sectionHeader(title: String) -> some View {
        // Use localized string - this will use the rawValue as a key in the strings files
        Text(title.localized)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(.systemBackground))
    }
    
    // MARK: - Chat History Row
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
                    // Title with better styling
                    Text(history.title)
                        .lineLimit(1)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(chatViewModel.currentConversation?.id == history.id ? .blue : .primary)
                    
                    // Last message preview with better styling
                    Text(history.lastMessage)
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer(minLength: 4)
                
                // Add timestamp if needed
                Text(history.timestamp, style: .date)
                    .font(.caption2)
                    .foregroundColor(.secondary)
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