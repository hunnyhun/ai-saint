import SwiftUI
import FirebaseAuth

struct SidebarView: View {
    // MARK: - Properties
    @Binding var showAuthView: Bool
    @Binding var selectedFeature: Models.Feature?
    @Bindable var chatViewModel: ChatViewModel
    @State private var showSettingsSheet = false
    
    // Environment
    let userStatusManager = UserStatusManager.shared
    let notificationManager = NotificationManager.shared
    @State private var showPaywall = false
    @State private var showAccountMenu = false
    @State private var showDailyQuote = false
    
    // MARK: - Body
    var body: some View {
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
                        Text("noChatsYet".localized)
                            .foregroundColor(.gray)
                            .padding()
                    } else {
                        // Display sections using our new sectionedHistory property
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
        userProfileView
            .sheet(isPresented: $showSettingsSheet) {
                SettingsView(showPaywall: .constant(false))
            }
    }
    
    // MARK: - User Profile View
    private var userProfileView: some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.bottom, 12)
            
            HStack(spacing: 16) {
                // User avatar
                Circle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 45, height: 45)
                    .overlay(
                        Image(systemName: "person.fill")
                            .foregroundColor(.gray)
                    )
                
                VStack(alignment: .leading, spacing: 4) {
                    // If anonymous user, show "Anonymous" and sign in button
                    if Auth.auth().currentUser?.isAnonymous == true {
                        Text("anonymousUser".localized)
                            .font(.subheadline)
                            .foregroundColor(.gray)
                        
                        Button {
                            showAuthView = true
                        } label: {
                            Text("signIn".localized)
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.blue)
                        }
                    } else {
                        // For regular users, show email and subscription status
                        if let email = userStatusManager.state.userEmail {
                            Text(email)
                                .font(.subheadline)
                                .lineLimit(1)
                        } else {
                            Text("anonymousUser".localized)
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                        
                        Text(userStatusManager.state.isPremium ? "premium".localized : "freeAccount".localized)
                            .font(.caption)
                            .foregroundColor(userStatusManager.state.isPremium ? .green : .gray)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                // Settings button
                Button {
                    showSettingsSheet = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .foregroundColor(.gray)
                        .frame(width: 22, height: 22)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
        .background(Color(.secondarySystemBackground))
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