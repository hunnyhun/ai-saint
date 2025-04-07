import SwiftUI
import FirebaseFirestore
import UIKit // Added for haptic feedback

// MARK: - Quote Model
struct DailyQuote: Identifiable {
    // Rule: Always add debug logs & comment in the code
    let id: String
    let quote: String
    let timestamp: Date
    let sentVia: String
    var isFavorite: Bool
    
    init(id: String, data: [String: Any]) {
        self.id = id
        self.quote = data["quote"] as? String ?? "Reflect on your spiritual journey today."
        
        // Parse timestamp or use current date as fallback
        if let timestamp = data["timestamp"] as? Timestamp {
            self.timestamp = timestamp.dateValue()
        } else {
            self.timestamp = Date()
        }
        
        self.sentVia = data["sentVia"] as? String ?? "unknown"
        self.isFavorite = data["isFavorite"] as? Bool ?? false
    }
}

// MARK: - Daily Quote View Model
@Observable final class DailyQuoteViewModel {
    // Properties
    var quotes: [DailyQuote] = []
    var isLoading = false
    var currentQuote: String?
    var currentQuoteDate: Date?
    var fromNotification = false
    private let db = Firestore.firestore()
    
    // MARK: - Initialization
    init(initialQuote: String? = nil, fromNotification: Bool = false) {
        // Set initial quote if provided (from notification)
        self.currentQuote = initialQuote
        self.fromNotification = fromNotification
        self.currentQuoteDate = Date() // Default to today
        
        // Debug log
        print("🌟 [DailyQuoteViewModel] Initialized with quote: \(initialQuote ?? "none"), from notification: \(fromNotification)")
    }
    
    // MARK: - Load Quotes
    func loadQuotes() async {
        // Debug log
        print("🌟 [DailyQuoteViewModel] Loading quotes")
        
        guard let userId = UserStatusManager.shared.state.userId else {
            print("❌ [DailyQuoteViewModel] Cannot load quotes - user not authenticated")
            return
        }
        
        isLoading = true
        
        do {
            // Get user's quotes
            let snapshot = try await db.collection("users")
                .document(userId)
                .collection("dailyQuotes")
                .order(by: "timestamp", descending: true)
                .limit(to: 30)
                .getDocuments()
            
            // Parse quotes
            let fetchedQuotes = snapshot.documents.map { doc in
                DailyQuote(id: doc.documentID, data: doc.data())
            }
            
            // Update on main thread
            await MainActor.run {
                self.quotes = fetchedQuotes
                
                // If we don't have a current quote yet, use the most recent one
                if self.currentQuote == nil && !fetchedQuotes.isEmpty {
                    self.currentQuote = fetchedQuotes[0].quote
                    self.currentQuoteDate = fetchedQuotes[0].timestamp
                }
                
                self.isLoading = false
            }
            
            print("✅ [DailyQuoteViewModel] Loaded \(fetchedQuotes.count) quotes")
        } catch {
            print("❌ [DailyQuoteViewModel] Error loading quotes: \(error.localizedDescription)")
            
            // Update on main thread
            await MainActor.run {
                self.isLoading = false
            }
        }
    }
    
    // MARK: - Toggle Favorite
    func toggleFavorite(for quote: DailyQuote) async {
        // Debug log
        print("🌟 [DailyQuoteViewModel] Toggling favorite for quote: \(quote.id)")
        
        do {
            // Toggle favorite status
            try await DailyQuoteFunctions.shared.updateQuoteFavoriteStatus(
                quoteId: quote.id,
                isFavorite: !quote.isFavorite
            )
            
            // Refresh quotes
            await loadQuotes()
            
        } catch {
            print("❌ [DailyQuoteViewModel] Error toggling favorite: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Save Current Quote as Favorite
    func saveCurrentQuoteAsFavorite() async {
        // Debug log
        print("🌟 [DailyQuoteViewModel] Saving current quote as favorite")
        
        guard let quote = currentQuote else {
            print("❌ [DailyQuoteViewModel] No current quote to save")
            return
        }
        
        do {
            // Save to favorites
            try await DailyQuoteFunctions.shared.saveQuoteToFavorites(quote: quote)
            
            // Refresh quotes
            await loadQuotes()
            
        } catch {
            print("❌ [DailyQuoteViewModel] Error saving favorite: \(error.localizedDescription)")
        }
    }
}

// MARK: - Daily Quote View
struct DailyQuoteView: View {
    // Rule: Always add debug logs
    @State private var viewModel: DailyQuoteViewModel
    @State private var animateQuote = false
    @State private var showFromNotificationBadge = false
    @Environment(\.dismiss) private var dismiss
    
    // MARK: - Initialization
    init(initialQuote: String? = nil, fromNotification: Bool = false) {
        _viewModel = State(initialValue: DailyQuoteViewModel(initialQuote: initialQuote, fromNotification: fromNotification))
        _showFromNotificationBadge = State(initialValue: fromNotification)
    }
    
    // MARK: - Body
    var body: some View {
        NavigationView {
            ZStack {
                Color.white.edgesIgnoringSafeArea(.all)
                
                ScrollView {
                    VStack(spacing: 25) {
                        if showFromNotificationBadge {
                            notificationBadge
                                .padding(.top, 12)
                        }
                        
                        // Main Quote Card
                        VStack(spacing: 30) {
                            // Yellow Cross at the top
                            TraditionalCross(
                                width: 60,
                                color: .yellow,
                                shadowColor: .yellow.opacity(0.2),
                                isAnimating: true
                            )
                            .frame(height: 100)
                            .scaleEffect(animateQuote ? 1.0 : 0.8)
                            .opacity(animateQuote ? 1.0 : 0.3)
                            
                            // Quote Content
                            if let quote = viewModel.currentQuote {
                                Text(quote)
                                    .font(.system(size: 24, weight: .bold))
                                    .multilineTextAlignment(.center)
                                    .foregroundColor(.black)
                                    .padding(.horizontal)
                                    .scaleEffect(animateQuote ? 1.0 : 0.95)
                                    .opacity(animateQuote ? 1.0 : 0)
                            } else if viewModel.isLoading {
                                ProgressView()
                                    .frame(height: 50)
                            } else {
                                Text("noQuoteAvailable".localized)
                                    .font(.system(size: 18))
                                    .foregroundColor(.gray)
                            }
                            
                            // Date
                            if let date = viewModel.currentQuoteDate {
                                Text(date, style: .date)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.gray)
                                    .opacity(animateQuote ? 1.0 : 0)
                            }
                        }
                        .padding(.vertical, 30)
                        .padding(.horizontal, 20)
                        .background(
                            RoundedRectangle(cornerRadius: 20)
                                .fill(Color.white)
                                .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 5)
                        )
                        .padding(.horizontal, 20)
                        
                        // Previous Quotes Section
                        VStack(alignment: .leading, spacing: 15) {
                            Text("previousQuotes".localized)
                                .font(.title3)
                                .fontWeight(.bold)
                                .padding(.horizontal, 20)
                                .padding(.top, 10)
                            
                            if viewModel.isLoading {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 30)
                            } else if viewModel.quotes.isEmpty {
                                Text("noPreviousQuotes".localized)
                                    .font(.system(size: 16))
                                    .foregroundColor(.gray)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 30)
                            } else {
                                // List of Previous Quotes
                                VStack(spacing: 15) {
                                    // Skip the first quote if it's the current quote
                                    ForEach(viewModel.quotes) { quote in
                                        PreviousQuoteRow(
                                            quote: quote,
                                            onToggleFavorite: {
                                                Task { await viewModel.toggleFavorite(for: quote) }
                                            }
                                        )
                                    }
                                }
                                .padding(.horizontal, 20)
                            }
                        }
                    }
                    .padding(.bottom, 30)
                }
            }
            .navigationTitle("quotes".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        // Debug log
                        print("📝 [DailyQuoteView] Close button tapped")
                        dismiss()
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.gray)
                            .padding(6)
                            .background(
                                Circle()
                                    .fill(Color(.systemGray6))
                            )
                    }
                    .accessibilityLabel("Close")
                }
            }
            .onAppear {
                // Debug log
                print("📝 [DailyQuoteView] View appeared")
                Task {
                    await viewModel.loadQuotes()
                    
                    // Trigger animation after quotes are loaded
                    withAnimation(.spring(response: 0.8, dampingFraction: 0.7)) {
                        animateQuote = true
                    }
                    
                    // Hide notification badge after a delay
                    if showFromNotificationBadge {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                            withAnimation {
                                showFromNotificationBadge = false
                            }
                        }
                    }
                }
                // Clear badge count when viewing quotes
                NotificationManager.shared.markNotificationsAsRead()
            }
        }
    }
    
    // MARK: - Helper Views
    
    // Notification Badge View
    private var notificationBadge: some View {
        HStack {
            Spacer()
            HStack(spacing: 6) {
                Text("fromNotification".localized)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.blue)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.blue.opacity(0.1))
                    .overlay(
                        Capsule()
                            .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                    )
            )
            Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Previous Quote Row Component
struct PreviousQuoteRow: View {
    let quote: DailyQuote
    let onToggleFavorite: () -> Void
    
    var body: some View {
        VStack {
            HStack(alignment: .top, spacing: 15) {
                // Red Cross Icon
                TraditionalCross(
                    width: 16,
                    color: .red,
                    shadowColor: .clear
                )
                .frame(width: 20, height: 30)
                .padding(.top, 2)
                
                VStack(alignment: .leading, spacing: 6) {
                    // Quote Text
                    Text(quote.quote)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.black)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    
                    // Verse Reference (if applicable)
                    if quote.quote.contains("—") {
                        let components = quote.quote.components(separatedBy: "—")
                        if components.count > 1 {
                            Text(components[1].trimmingCharacters(in: .whitespacesAndNewlines))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.gray)
                        }
                    }
                    
                    // Date
                    Text(quote.timestamp, style: .date)
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                // Favorite Button
                Button(action: onToggleFavorite) {
                    Image(systemName: quote.isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 22))
                        .foregroundColor(quote.isFavorite ? .red : .gray.opacity(0.5))
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 15)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white)
                    .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
            )
        }
    }
}

// Preview Provider
#if DEBUG
struct DailyQuoteView_Previews: PreviewProvider {
    static var previews: some View {
        // Provide mock data for preview
        DailyQuoteView(initialQuote: "This is a sample quote for the preview.", fromNotification: true)
    }
}
#endif 