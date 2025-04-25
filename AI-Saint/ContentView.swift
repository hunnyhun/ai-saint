import SwiftUI

// MARK: - Keyboard Extension
#if canImport(UIKit)
import UIKit
extension View {
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
#endif

struct ContentView: View {
    // MARK: - Properties
    let userStatusManager = UserStatusManager.shared
    let notificationManager = NotificationManager.shared
    @State private var showPaywall = false
    @State private var showAuthView = false
    @State private var selectedFeature: Models.Feature? = .chat
    @State private var showSidebar = false
    @State private var chatViewModel = ChatViewModel()
    @State private var sidebarRefreshTrigger = UUID()
    @State private var lastRefreshTime = Date()
    @Environment(\.scenePhase) private var scenePhase
    @State private var sidebarView: SidebarView?
    @State private var justLoggedIn = false  // Track if user just logged in
    
    // New states for daily quote view
    @State private var showDailyQuote = false
    @State private var currentQuote: String?
    
    // MARK: - Body
    var body: some View {
        Group {
            mainContent
        }
        .animation(.easeInOut(duration: 0.3), value: userStatusManager.state.isAuthenticated)
        .sheet(isPresented: $showAuthView) {
            AuthenticationView()
        }
        .task {
            // Check user status during initial load
            await userStatusManager.refreshUserState()
            
            // Initialize app when loaded
            chatViewModel.loadChatHistory()
            
            // Check notification permissions (but don't show prompt yet)
            let permissionStatus = await notificationManager.checkNotificationStatus()
            print("📱 [ContentView] Initial notification permission status: \(permissionStatus)")
            
            // Add observer for quote notification taps
            setupNotificationObservers()
        }
        .onChange(of: userStatusManager.state.isAuthenticated) { oldValue, newValue in
            if !oldValue && newValue {
                // User just logged in
                print("📱 [ContentView] User just logged in, will show notification prompt")
                justLoggedIn = true
                
                // Show notification prompt after a delay to allow UI to settle
                checkNotificationPermission(afterDelay: 2.0)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Refresh data when app becomes active
                if userStatusManager.state.isAuthenticated {
                    chatViewModel.loadChatHistory()
                    
                    // Reset the just logged in flag
                    justLoggedIn = false
                }
            }
            else if newPhase == .background {
                // Ensure badge count is synchronized when going to background
                print("📱 [ContentView] App entering background, ensuring badge count is synchronized")
                NotificationManager.shared.synchronizeBadgeCount()
                dismissKeyboardAndCloseSidebar()
            }
            else if newPhase != .active {
                dismissKeyboardAndCloseSidebar()
            }
        }
    }
    
    // MARK: - Main Content
    private var mainContent: some View {
        NavigationStack {
            ZStack(alignment: .leading) {
                // Sidebar overlay for visual effect & tap-to-close
                if showSidebar {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.3), value: showSidebar)
                        .onTapGesture {
                            dismissKeyboardAndCloseSidebar()
                        }
                        .zIndex(1)
                }
                
                // Sidebar
                let view = SidebarView(
                    showAuthView: $showAuthView,
                    selectedFeature: $selectedFeature,
                    chatViewModel: chatViewModel
                )
                view
                    .frame(width: 300)
                    .frame(maxWidth: 300, alignment: .leading)
                    .offset(x: showSidebar ? 0 : -300)
                    .zIndex(2)
                    .id(sidebarRefreshTrigger)
                    .onAppear {
                        sidebarView = view
                    }
                
                // Main Content with Navigation
                VStack(spacing: 0) {
                    // Main Content View - passing sidebar control
                    ChatView(viewModel: chatViewModel, showSidebarCallback: $showSidebar)
                        .id(selectedFeature)
                        .disabled(showSidebar) // Disable interaction when sidebar is open
                }
                .background(Color(.systemBackground))
            }
            .navigationBarHidden(true)
            .overlay {
                if userStatusManager.isLoading {
                    ProgressView()
                        .scaleEffect(1.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.ultraThinMaterial)
                }
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
                    .onDisappear {
                        if userStatusManager.state.isPremium {
                            withAnimation {
                                refreshSidebar()
                            }
                            chatViewModel.loadChatHistory()
                            let generator = UINotificationFeedbackGenerator()
                            generator.notificationOccurred(.success)
                        }
                    }
            }
            // Add Daily Quote Sheet with separate onDismiss handler
            .sheet(isPresented: $showDailyQuote, onDismiss: dailyQuoteDismissed) {
                if let quote = currentQuote {
                    // From notification
                    DailyQuoteView(initialQuote: quote, fromNotification: true)
                } else {
                    // Regular view
                    DailyQuoteView(fromNotification: false)
                }
            }
            .gesture(
                DragGesture()
                    .onEnded { gesture in
                        let threshold: CGFloat = 50
                        if gesture.translation.width > threshold && !showSidebar {
                            dismissKeyboardAndOpenSidebar()
                        } else if gesture.translation.width < -threshold && showSidebar {
                            dismissKeyboardAndCloseSidebar()
                        }
                    }
            )
            .onChange(of: selectedFeature) { _, _ in
                dismissKeyboardAndCloseSidebar()
            }
            .onChange(of: userStatusManager.state.isPremium) { _, isPremium in
                if isPremium {
                    chatViewModel.loadChatHistory()
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    private func refreshSidebar() {
        guard userStatusManager.state.isPremium else { return }
        
        let now = Date()
        if now.timeIntervalSince(lastRefreshTime) > 0.5 {
            withAnimation {
                chatViewModel.loadChatHistory()
                sidebarRefreshTrigger = UUID()
                lastRefreshTime = now
                print("[ContentView] Refreshed sidebar at \(now)")
            }
        }
    }
    
    private func dismissKeyboardAndOpenSidebar() {
        hideKeyboard()
        withAnimation(.easeInOut(duration: 0.3)) {
            showSidebar = true
            if userStatusManager.state.isPremium {
                refreshSidebar()
            }
        }
    }
    
    private func dismissKeyboardAndCloseSidebar() {
        hideKeyboard()
        withAnimation(.easeInOut(duration: 0.3)) {
            showSidebar = false
        }
    }
    
    // MARK: - Notification Handling
    private func setupNotificationObservers() {
        print("📱 [ContentView] Setting up notification observers")
        
        // Remove any existing observers
        NotificationCenter.default.removeObserver(self)
        
        // Add observer for quote notification taps
        NotificationCenter.default.addObserver(
            forName: Notification.Name("OpenDailyQuoteView"),
            object: nil,
            queue: .main
        ) { notification in
            // Extract quote from notification
            if let userInfo = notification.userInfo,
               let quote = userInfo["quote"] as? String {
                print("📱 [ContentView] Received open quote view notification: \(quote)")
                
                // Close sidebar if it's open
                if self.showSidebar {
                    self.dismissKeyboardAndCloseSidebar()
                }
                
                // Set the current quote
                self.currentQuote = quote
                
                // Show the daily quote view with a slight delay to ensure UI transitions
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    print("📱 [ContentView] Opening DailyQuoteView")
                    self.showDailyQuote = true
                }
            }
        }
    }
    
    private func dailyQuoteDismissed() {
        print("📱 [ContentView] DailyQuoteView dismissed")
        
        // Reset quote after sheet is dismissed
        currentQuote = nil
    }
    
    // MARK: - Notification Permission Helper
    private func checkNotificationPermission(afterDelay: TimeInterval) {
        Task {
            // Check if notifications are authorized
            let isAuthorized = await notificationManager.checkNotificationStatus()
            print("📱 [ContentView] Notification permission check: \(isAuthorized ? "Authorized" : "Not Authorized")")
            
            // If not authorized and this is a first login, request permission directly
            if !isAuthorized && justLoggedIn {
                // Request after delay to allow transitions to complete
                try? await Task.sleep(nanoseconds: UInt64(afterDelay * 1_000_000_000))
                print("📱 [ContentView] Directly requesting system notification permission")
                await requestNotificationPermission()
            }
        }
    }
    
    // MARK: - Request Notification Permission
    private func requestNotificationPermission() async {
        // Directly call the centralized permission request method
        print("📱 [ContentView] Requesting notification permission")
        let _ = await notificationManager.requestNotificationPermission()
    }
    
    // User profile at bottom of sidebar
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
}

// MARK: - Preview
#Preview {
    ContentView()
}
