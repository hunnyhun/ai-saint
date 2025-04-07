import Foundation
import SwiftUI
import UIKit

// MARK: - Localization Manager
@Observable final class LocalizationManager {
    // Singleton instance
    static let shared = LocalizationManager()
    
    // Currently selected language
    var currentLanguage: String {
        // Get from UserDefaults or use system language
        UserDefaults.standard.string(forKey: "app_language") ?? Locale.current.identifier
    }
    
    // Available languages
    let availableLanguages = [
        "en": "English",
        "es": "Español",
        "es-419": "Español (Latinoamérica)",
        "it": "Italiano",
        "pt": "Português",
        "pt-BR": "Português (Brasil)"
    ]
    
    // Private initializer for singleton
    private init() {
        // Rule: Always add debug logs
        print("📱 [LocalizationManager] Initialized with language: \(currentLanguage)")
    }
    
    // MARK: - Helper Methods
    
    // Get the display name for the current language
    func getCurrentLanguageDisplayName() -> String {
        // First check exact match
        if let exactMatch = availableLanguages[currentLanguage] {
            return exactMatch
        }
        
        // Then try language code only
        let langCode = getLanguageCode(from: currentLanguage)
        return availableLanguages[langCode] ?? "English"
    }
    
    // Extract language code from locale identifier (e.g., "en_US" -> "en")
    func getLanguageCode(from localeIdentifier: String) -> String {
        localeIdentifier.split(separator: "_").first.map(String.init) ?? "en"
    }
    
    // Check if app is running in a specific language
    func isLanguage(_ languageCode: String) -> Bool {
        // Check exact match first
        if currentLanguage == languageCode {
            return true
        }
        
        // Then check base language
        return getLanguageCode(from: currentLanguage) == languageCode
    }
    
    // MARK: - Language Settings
    
    // Opens system settings for language selection
    func openLanguageSettings() {
        // Rule: Always add debug logs
        print("📱 [LocalizationManager] Opening language settings")
        
        if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(settingsUrl)
            print("📱 [LocalizationManager] Opened system settings")
        } else {
            print("❌ [LocalizationManager] Failed to open system settings")
        }
    }
} 