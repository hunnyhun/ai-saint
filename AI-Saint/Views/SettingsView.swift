import SwiftUI
import UserNotifications
import UIKit
import RevenueCat

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var showPaywall: Bool
    
    // Access the shared SubscriptionManager
    @State private var subscriptionManager = SubscriptionManager.shared
    @State private var showingRestoreAlert = false
    @State private var restoreAlertMessage = ""
    @State private var isRestoring = false
    @State private var showingDeleteConfirm = false
    @State private var isDeleting = false
    @State private var deleteError: String?
    
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
                
                // MARK: - Purchases Section
                Section("purchases".localized) {
                    Button {
                        Task {
                            isRestoring = true
                            do {
                                print("Attempting to restore purchases...")
                                try await subscriptionManager.restorePurchases()
                                if subscriptionManager.currentSubscription == .premium {
                                    restoreAlertMessage = "restoreSuccessMessage".localized
                                } else {
                                    restoreAlertMessage = subscriptionManager.errorMessage ?? "restoreNoPurchasesFound".localized
                                }
                                print("Restore finished. Message: \(restoreAlertMessage)")
                            } catch {
                                print("ERROR: Restore failed in View: \(error.localizedDescription)")
                                restoreAlertMessage = "restoreFailedMessage".localized
                            }
                            isRestoring = false
                            showingRestoreAlert = true
                        }
                    } label: {
                        HStack {
                            if isRestoring {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .frame(width: 20, height: 20)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text("restorePurchases".localized)
                        }
                    }
                    .disabled(isRestoring)
                }
                
                // MARK: - Delete Account Section
                Section("account".localized) {
                    Button(role: .destructive) {
                        showingDeleteConfirm = true
                    } label: {
                        HStack {
                            if isDeleting {
                                ProgressView()
                            } else {
                                Image(systemName: "trash")
                                Text("deleteAccount".localized)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isDeleting)
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
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                            Text("signOut".localized)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("settings".localized)
            .navigationBarTitleDisplayMode(.inline)
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
        .alert(isPresented: $showingRestoreAlert) {
            Alert(title: Text("restorePurchases".localized), message: Text(restoreAlertMessage), dismissButton: .default(Text("ok".localized)))
        }
        .alert("deleteAccountTitle".localized, isPresented: $showingDeleteConfirm) {
            Button("cancelButton".localized, role: .cancel) { }
            Button("deleteButton".localized, role: .destructive) {
                Task {
                    isDeleting = true
                    deleteError = nil
                    do {
                        print("📱 [SettingsView] Attempting account deletion...")
                        try await userStatusManager.deleteAccount()
                        print("✅ [SettingsView] Account deleted successfully.")
                        dismiss()
                    } catch {
                        print("❌ [SettingsView] Account deletion failed: \(error.localizedDescription)")
                        deleteError = "deleteAccountFailedMessage".localized + "\\n" + error.localizedDescription
                    }
                    isDeleting = false
                }
            }
        } message: {
            Text("deleteAccountConfirmMessage".localized)
        }
        .alert("errorTitle".localized, isPresented: .constant(deleteError != nil), actions: {
            Button("ok".localized) {
                deleteError = nil
            }
        }, message: {
            Text(deleteError ?? "unknownError".localized)
        })
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