import SwiftUI

struct SettingsView: View {
    let userStatusManager = UserStatusManager.shared
    @Environment(\.dismiss) private var dismiss
    @Binding var showPaywall: Bool
    @State private var hapticFeedbackEnabled = true
    @State private var autoCorrectEnabled = true
    
    var body: some View {
        NavigationView {
            List {
                Section("ACCOUNT") {
                    if let email = userStatusManager.state.userEmail {
                        HStack {
                            Image(systemName: "envelope")
                            Text("Email")
                            Spacer()
                            Text(email)
                                .foregroundColor(.gray)
                        }
                    }
                    
                    HStack {
                        Image(systemName: "star")
                        Text("Subscription")
                        Spacer()
                        Text(userStatusManager.state.subscriptionTier.displayText.capitalized)
                            .foregroundColor(.gray)
                    }
                    
                    if !userStatusManager.state.isPremium {
                        Button(action: {
                            dismiss()
                            showPaywall = true
                        }) {
                            Label("Upgrade to Plus", systemImage: "arrow.up.circle")
                        }
                    }
                    
                    Button(action: {
                        // Handle restore purchases
                    }) {
                        Label("Restore purchases", systemImage: "arrow.clockwise")
                    }
                }
                
                Section("APP") {
                    HStack {
                        Image(systemName: "globe")
                        Text("App Language")
                        Spacer()
                        Text("English")
                            .foregroundColor(.gray)
                        Image(systemName: "chevron.right")
                            .foregroundColor(.gray)
                            .font(.caption)
                    }
                    
                    HStack {
                        Image(systemName: "paintbrush")
                        Text("Theme")
                        Spacer()
                        Text("Catholic")
                            .foregroundColor(.purple)
                        Image(systemName: "chevron.down")
                            .foregroundColor(.gray)
                            .font(.caption)
                    }
                    
                    Toggle(isOn: $hapticFeedbackEnabled) {
                        Label("Haptic Feedback", systemImage: "iphone.radiowaves.left.and.right")
                    }
                    
                    Toggle(isOn: $autoCorrectEnabled) {
                        Label("Correct Spelling Automatically", systemImage: "textformat.abc")
                    }

                    Toggle(isOn: .constant(true)) {
                        Label("Private Mode", systemImage: "lock.fill")
                    }
                    .disabled(true)
                }

                Section("CONFESSION") {
                    HStack {
                        Image(systemName: "cross.fill")
                        Text("Prayer Language")
                        Spacer()
                        Text("Traditional")
                            .foregroundColor(.gray)
                        Image(systemName: "chevron.right")
                            .foregroundColor(.gray)
                            .font(.caption)
                    }
                    
                    Toggle(isOn: .constant(true)) {
                        Label("Anonymous Mode", systemImage: "person.fill.questionmark")
                    }
                    .disabled(true)
                    
                    Toggle(isOn: .constant(true)) {
                        Label("Clear History After Session", systemImage: "trash.fill")
                    }
                    .disabled(true)
                }
                
                Section {
                    Button(role: .destructive) {
                        Task {
                            do {
                                try await userStatusManager.signOut()
                                dismiss()
                            } catch {
                                print("ERROR: Sign out failed: \(error.localizedDescription)")
                            }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            Text("Sign Out")
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    SettingsView(showPaywall: .constant(false))
} 