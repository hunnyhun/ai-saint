import SwiftUI
// No need to import TraditionalCross as it should be part of the same module

// Extension to dismiss keyboard
extension UIApplication {
    func endEditing() {
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        print("DEBUG: Keyboard dismissed via UIApplication extension")
    }
}

struct ChatView: View {
    // MARK: - Properties
    let viewModel: ChatViewModel
    let userStatusManager = UserStatusManager.shared
    @State private var messageText = ""
    @FocusState private var isTextFieldFocused: Bool
    @State private var showSidebar = false
    @State private var showPaywall = false
    @Binding var showSidebarCallback: Bool
    @State private var shouldScrollToBottom = false
    
    // Note: ChatViewModel should implement isRateLimited property
    // that gets set to true when receiving a 429 rate limit error from backend
    
    // Debug helper
    private func debugLog(_ message: String) {
        print("[ChatView] \(message)")
    }
    
    // Simple default initializer for preview
    init(viewModel: ChatViewModel, showSidebarCallback: Binding<Bool> = .constant(false)) {
        self.viewModel = viewModel
        self._showSidebarCallback = showSidebarCallback
    }
    
    // MARK: - Body
    var body: some View {
        VStack(spacing: 0) {
            // Custom toolbar
            HStack(spacing: 16) {
                // Menu button
                Button(action: {
                    print("[Navigation] Menu button tapped")
                    withAnimation(.spring()) {
                        showSidebarCallback = true
                    }
                }) {
                    Image(systemName: "line.3.horizontal")
                        .foregroundColor(.primary)
                        .font(.system(size: 22, weight: .semibold))
                }
                .frame(width: 36, height: 36)
                
                // Title
                Group {
                    if let conversation = viewModel.currentConversation {
                        Text(conversation.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    } else {
                        Text("New Chat")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary)
                    }
                }
                .frame(maxWidth: .infinity)
                
                // New Chat button
                Button(action: {
                    print("[Navigation] New chat button tapped")
                    viewModel.startNewChat()
                }) {
                    // Simple plus in circle like the image - made smaller
                    ZStack {
                        Circle()
                            .stroke(Color.black, lineWidth: 1.5)
                            .frame(width: 22, height: 22)
                        
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.black)
                    }
                }
                .disabled(viewModel.isLoading)
            }
            .padding(.horizontal)
            .frame(height: 44)
            .background(Color.white)
            
            Divider()
                .opacity(0.5)
        
            // Messages list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        // Empty state for new chat
                        if viewModel.messages.isEmpty {
                            newChatWelcomeView
                                .padding(.top, 40)
                        }
                        
                        // Messages
                        ForEach(viewModel.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                        
                        // Show typing indicator when loading
                        if viewModel.isLoading {
                            HStack {
                                TypingIndicator()
                                    .padding()
                                    .background(Color.white)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16)
                                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                                    )
                                    .cornerRadius(16)
                                Spacer()
                            }
                            .padding(.horizontal)
                        }
                        
                        // Show premium button only when rate limit error occurs
                        if viewModel.isRateLimited {
                            premiumButton
                        }
                        
                        // Bottom anchor view
                        Color.clear
                            .frame(height: 1)
                            .id("bottomID")
                    }
                    .padding()
                }
                .background(Color.white)
                .onChange(of: viewModel.messages.count) { _, _ in
                    debugLog("Messages count changed, scrolling to bottom")
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo("bottomID", anchor: .bottom)
                    }
                }
                .onChange(of: shouldScrollToBottom) { _, shouldScroll in
                    if shouldScroll {
                        debugLog("Manual scroll to bottom triggered")
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo("bottomID", anchor: .bottom)
                        }
                        shouldScrollToBottom = false
                    }
                }
                .simultaneousGesture(
                    DragGesture().onChanged { _ in
                        if isTextFieldFocused {
                            debugLog("Drag detected, dismissing keyboard")
                            isTextFieldFocused = false
                        }
                    }
                )
            }
            
            // Input area
            VStack(spacing: 0) {
                // Error message - show all errors except rate limit, which gets special treatment
                if let error = viewModel.error, !viewModel.isRateLimited {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.footnote)
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .multilineTextAlignment(.center)
                }
                
                // Input container
                HStack(alignment: .bottom, spacing: 8) {
                    // Message input field
                    ZStack(alignment: .trailing) {
                        TextField("Confess your thoughts...", text: $messageText, axis: .vertical)
                            .textFieldStyle(.plain)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 16)
                            .padding(.trailing, 40)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.white)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                            )
                            .lineLimit(1...5)
                            .focused($isTextFieldFocused)
                            .disabled(viewModel.isLoading)
                            .submitLabel(.send)
                            .onSubmit {
                                debugLog("Submit triggered, sending message")
                                sendMessage()
                            }
                            .onChange(of: viewModel.isLoading) { _, isLoading in
                                if isLoading {
                                    debugLog("Loading started, dismissing keyboard")
                                    isTextFieldFocused = false
                                }
                            }
                            .onChange(of: isTextFieldFocused) { _, focused in
                                if focused {
                                    debugLog("TextField focused, triggering scroll")
                                    shouldScrollToBottom = true
                                }
                            }
                        
                        // Send button
                        Button(action: sendMessage) {
                            Image(systemName: messageText.isEmpty ? "circle" : "arrow.up.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(messageText.isEmpty || viewModel.isLoading ? .gray.opacity(0.5) : .blue)
                        }
                        .disabled(messageText.isEmpty || viewModel.isLoading)
                        .padding(.trailing, 16)
                        .scaleEffect(messageText.isEmpty ? 0.8 : 1.0)
                        .animation(.spring(response: 0.3), value: messageText.isEmpty)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .padding(.bottom, 8) // Add bottom padding for spacing
            }
            .background(
                Color.white
            )
            .clipShape(
                RoundedCorners(tl: 24, tr: 24, bl: 0, br: 0)
            )
            .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: -3)
            .edgesIgnoringSafeArea(.bottom) // Ensure input area extends to bottom edge
            .onAppear {
                print("DEBUG: Input area with rounded corners appeared - padding added")
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
        // Apply to entire view to ensure taps anywhere dismiss keyboard
        .onTapGesture {
            UIApplication.shared.endEditing()
            isTextFieldFocused = false
            print("DEBUG: Tapped anywhere in the view, dismissing keyboard")
        }
        .background(Color.white)
        .safeAreaInset(edge: .bottom) {
            // Provide minimal padding to handle bottom safe area on devices with home indicator
            Spacer().frame(height: 5)
        }
    }
    
    // MARK: - Helper Methods
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.3)) {
            proxy.scrollTo("bottomID", anchor: .bottom)
        }
    }
    
    private func sendMessage() {
        guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        debugLog("Sending message: \(messageText)")
        let text = messageText
        messageText = ""
        
        // Dismiss keyboard immediately when sending
        isTextFieldFocused = false
        
        // Trigger scroll to bottom
        shouldScrollToBottom = true
        
        // Send message after keyboard is dismissed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            viewModel.sendMessage(text)
        }
    }
    
    // MARK: - Premium Button View
    private var premiumButton: some View {
        Button(action: {
            debugLog("Opening paywall due to rate limit")
            showPaywall = true
        }) {
            VStack(spacing: 8) {
                Text("Message limit reached")
                    .font(.headline)
                    .foregroundColor(.white)
                
                HStack {
                    Image(systemName: "star.fill")
                        .font(.system(size: 20))
                    Text("Upgrade to Premium for unlimited messages")
                        .font(.subheadline)
                }
                .foregroundColor(.white)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 24)
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.8, green: 0.7, blue: 0.3),
                        Color(red: 0.7, green: 0.5, blue: 0.2)
                    ]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .cornerRadius(20)
            .shadow(radius: 2)
        }
        .padding(.vertical, 8)
        // Add debug print
        .onAppear {
            print("DEBUG: Rate limit reached - showing premium button")
        }
    }
    
    // MARK: - Welcome View for New Chat
    private var newChatWelcomeView: some View {
        VStack(spacing: 16) {
            TraditionalCross(
                width: 40,
                color: Color.yellow
            )
            .frame(width: 40, height: 64)
            
            Text("Welcome to Digital Confession")
                .font(.headline)
            
            Text("In the name of the Father, and of the Son, and of the Holy Spirit.")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            VStack(spacing: 12) {
                ForEach(["Bless me Father, for I have sinned", "I need guidance with a moral dilemma", "How can I seek forgiveness?"], id: \.self) { suggestion in
                    Button(action: {
                        messageText = suggestion
                        sendMessage()
                    }) {
                        Text(suggestion)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 16)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(16)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

// MARK: - Message Bubble
struct MessageBubble: View {
    let message: ChatMessage
    
    // Convert markdown to AttributedString
    private func markdownAttributedString(_ text: String) -> AttributedString {
        do {
            // Debug markdown parsing
            debugPrint("[MessageBubble] Parsing markdown:", text)
            return try AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            ))
        } catch {
            debugPrint("[MessageBubble] Failed to parse markdown:", error)
            return AttributedString(text)
        }
    }
    
    var body: some View {
        HStack {
            if message.isUser {
                Spacer()
                Text(message.text)
                    .padding()
                    .background(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
                    .foregroundColor(.primary)
                    .cornerRadius(16)
                    .textSelection(.enabled)
            } else {
                VStack(alignment: .leading) {
                    HStack {
                        TraditionalCross(
                            width: 16,
                            color: Color.yellow,
                            shadowColor: .clear
                        )
                        .frame(width: 16, height: 25)
                        
                        Text("Priest")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding(.bottom, 4)
                    
                    Text(markdownAttributedString(message.text))
                        .textSelection(.enabled)
                }
                .padding()
                .background(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
                .cornerRadius(16)
                Spacer()
            }
        }
    }
}

// MARK: - Typing Indicator
struct TypingIndicator: View {
    @State private var animationOffset = 0.0
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .frame(width: 6, height: 6)
                    .foregroundColor(.gray)
                    .offset(y: sin(animationOffset + Double(index) * 0.5) * 2)
            }
        }
        .onAppear {
            withAnimation(Animation.linear(duration: 1.0).repeatForever()) {
                animationOffset = 2 * .pi
            }
        }
    }
}

// Add this custom shape for rounded specific corners
struct RoundedCorners: Shape {
    var tl: CGFloat = 0.0
    var tr: CGFloat = 0.0
    var bl: CGFloat = 0.0
    var br: CGFloat = 0.0
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        
        let w = rect.size.width
        let h = rect.size.height
        
        // Make sure we don't exceed the size of the rectangle
        let tl = min(min(self.tl, h/2), w/2)
        let tr = min(min(self.tr, h/2), w/2)
        let bl = min(min(self.bl, h/2), w/2)
        let br = min(min(self.br, h/2), w/2)
        
        path.move(to: CGPoint(x: w / 2.0, y: 0))
        path.addLine(to: CGPoint(x: w - tr, y: 0))
        path.addArc(center: CGPoint(x: w - tr, y: tr), radius: tr, startAngle: Angle(degrees: -90), endAngle: Angle(degrees: 0), clockwise: false)
        path.addLine(to: CGPoint(x: w, y: h - br))
        path.addArc(center: CGPoint(x: w - br, y: h - br), radius: br, startAngle: Angle(degrees: 0), endAngle: Angle(degrees: 90), clockwise: false)
        path.addLine(to: CGPoint(x: bl, y: h))
        path.addArc(center: CGPoint(x: bl, y: h - bl), radius: bl, startAngle: Angle(degrees: 90), endAngle: Angle(degrees: 180), clockwise: false)
        path.addLine(to: CGPoint(x: 0, y: tl))
        path.addArc(center: CGPoint(x: tl, y: tl), radius: tl, startAngle: Angle(degrees: 180), endAngle: Angle(degrees: 270), clockwise: false)
        path.closeSubpath()
        
        return path
    }
}

#Preview {
    NavigationView {
        ChatView(viewModel: ChatViewModel())
    }
} 