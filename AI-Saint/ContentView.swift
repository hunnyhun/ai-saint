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
    @State private var showNotificationPermissionAlert = false
    @State private var justLoggedIn = false  // Track if user just logged in
    
    // New states for daily quote view
    @State private var showDailyQuote = false
    @State private var currentQuote: String?
    
    // MARK: - Body
    var body: some View {
        Group {
            if !userStatusManager.state.isAuthenticated {
                AuthenticationView()
                    .transition(.opacity)
            } else {
                mainContent
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: userStatusManager.state.isAuthenticated)
        .task {
            // Check user status during initial load
            await userStatusManager.refreshUserState()
            
            // Initialize app if user is authenticated
            if userStatusManager.state.isAuthenticated {
                chatViewModel.loadChatHistory()
                
                // Check notification permissions (but don't show prompt yet)
                let permissionStatus = await notificationManager.checkNotificationStatus()
                print("📱 [ContentView] Initial notification permission status: \(permissionStatus)")
            }
            
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
                    
                    // Only check notification permission on app becoming active
                    // if we didn't just log in (to avoid double prompts)
                    if !justLoggedIn {
                        checkNotificationPermission(afterDelay: 1.0)
                    }
                    
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
                // Full screen overlay to handle taps
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if showSidebar {
                            dismissKeyboardAndCloseSidebar()
                        }
                    }
                
                // Sidebar overlay for visual effect
                if showSidebar {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .transition(.opacity)
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
            .sheet(isPresented: $showAuthView) {
                AuthenticationView()
                    .onDisappear {
                        if userStatusManager.state.isAuthenticated {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                refreshSidebar()
                            }
                        }
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
            // Add notification permission alert
            .alert("Enable Spiritual Notifications", isPresented: $showNotificationPermissionAlert) {
                Button("Allow", role: .none) {
                    Task {
                        await requestNotificationPermission()
                    }
                }
                Button("Not Now", role: .cancel) {}
            } message: {
                Text("We'd like to send you daily spiritual quotes to inspire your journey.")
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
        withAnimation(.spring()) {
            showSidebar = true
            if userStatusManager.state.isPremium {
                refreshSidebar()
            }
        }
    }
    
    private func dismissKeyboardAndCloseSidebar() {
        hideKeyboard()
        withAnimation(.spring()) {
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
            
            // If not authorized, show permission prompt after delay
            if !isAuthorized {
                // Show after delay to allow transitions to complete
                DispatchQueue.main.asyncAfter(deadline: .now() + afterDelay) {
                    print("📱 [ContentView] Showing notification permission alert")
                    showNotificationPermissionAlert = true
                }
            }
        }
    }
    
    // MARK: - Request Notification Permission
    private func requestNotificationPermission() async {
        // Directly call the centralized permission request method
        print("📱 [ContentView] Requesting notification permission")
        await notificationManager.requestNotificationPermission()
    }
}

// MARK: - Preview
#Preview {
    ContentView()
}
