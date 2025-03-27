import SwiftUI

struct ContentView: View {
    // MARK: - Properties
    let userStatusManager = UserStatusManager.shared
    @State private var showPaywall = false
    @State private var showAuthView = false
    @State private var selectedFeature: Models.Feature? = .chat
    @State private var showSidebar = false
    @State private var chatViewModel = ChatViewModel()
    @State private var sidebarRefreshTrigger = UUID()
    @State private var lastRefreshTime = Date()
    @Environment(\.scenePhase) private var scenePhase
    @State private var sidebarView: SidebarView?
    
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
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Refresh data when app becomes active
                if userStatusManager.state.isAuthenticated {
                    chatViewModel.loadChatHistory()
                }
            }
            if newPhase != .active {
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
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        withAnimation(.spring()) {
            showSidebar = true
            if userStatusManager.state.isPremium {
                refreshSidebar()
            }
        }
    }
    
    private func dismissKeyboardAndCloseSidebar() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        withAnimation(.spring()) {
            showSidebar = false
        }
    }
}

// MARK: - Preview
#Preview {
    ContentView()
}
