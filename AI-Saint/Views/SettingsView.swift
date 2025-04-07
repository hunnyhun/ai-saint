import SwiftUI
import UserNotifications
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var showPaywall: Bool
    
    // Environment objects
    let userStatusManager = UserStatusManager.shared
    let notificationManager = NotificationManager.shared
    let localizationManager = LocalizationManager.shared
    
    var body: some View {
        NavigationView {
            Form {
                // MARK: - User Section
                userSection
                
                // MARK: - App Section
                Section("app".localized) {
                    // Notification toggle - uses custom permission flow
                    notificationsSection
                    
                    // Language settings button
                    Button {
                        openLanguageSettings()
                    } label: {
                        HStack {
                            Image(systemName: "globe")
                            Text("language".localized)
                            Spacer()
                            Text(localizationManager.getCurrentLanguageDisplayName())
                                .foregroundColor(.gray)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    .accessibilityHint("openSettings".localized)
                }
                
                // MARK: - Sign Out Section
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
                            Text("signOut".localized)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("settings".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done".localized) {
                        dismiss()
                    }
                }
            }
            .onAppear {
                // Check notification status when view appears
                Task {
                    // Rule: Always add debug logs
                    print("📱 [SettingsView] View appeared, checking notification status")
                    
                    // Always force check the actual system notification status
                    let isEnabled = await notificationManager.checkNotificationStatus()
                    
                    // Debug log the current state after checking
                    print("📱 [SettingsView] After system check: isEnabled=\(isEnabled), manager.isEnabled=\(notificationManager.isNotificationsEnabled)")
                }
            }
        }
    }
    
    // MARK: - User Section View
    private var userSection: some View {
        Section {
            HStack(spacing: 12) {
                // User avatar
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.gray)
                
                // User info
                VStack(alignment: .leading, spacing: 2) {
                    if let email = userStatusManager.state.userEmail {
                        Text(email)
                            .font(.headline)
                    } else {
                        Text("anonymousUser".localized)
                            .font(.headline)
                    }
                    
                    Text(userStatusManager.state.isPremium ? "premium".localized : "freeAccount".localized)
                        .font(.subheadline)
                        .foregroundColor(userStatusManager.state.isPremium ? .green : .secondary)
                }
                
                Spacer()
            }
            .padding(.vertical, 8)
        }
    }
    
    // MARK: - Notifications Section
    private var notificationsSection: some View {
        Button {
            openSystemSettings()
        } label: {
            HStack {
                Image(systemName: "bell.fill")
                Text("notificationPreferences".localized)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
        .onAppear {
            Task {
                // Check current notification status
                await notificationManager.checkNotificationStatus()
            }
        }
    }
    
    // MARK: - Open System Settings
    private func openSystemSettings() {
        // Rule: Always add debug logs
        print("📱 [SettingsView] Opening system settings app")
        
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
    
    // MARK: - Open Language Settings
    private func openLanguageSettings() {
        // Rule: Always add debug logs
        print("📱 [SettingsView] Opening language settings in system app")
        
        // Use the localization manager to open language settings
        localizationManager.openLanguageSettings()
    }
}

#Preview {
    SettingsView(showPaywall: .constant(false))
} 