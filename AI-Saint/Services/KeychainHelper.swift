import Foundation
import Security

enum KeychainError: Error {
    case saveError(OSStatus)
    case loadError(OSStatus)
    case unexpectedData
    case unhandledError(status: OSStatus)
}

class KeychainHelper {

    static let shared = KeychainHelper()
    private init() {} // Singleton

    private let service = "com.hunnyhun.ai-saint" // Replace with your actual app identifier
    private let anonymousIdAccount = "persistentAnonymousUserId"

    func saveAnonymousId(_ id: String) throws {
        guard let data = id.data(using: .utf8) else {
            print("Error: Could not convert ID to data.")
            // Or throw a specific error
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: anonymousIdAccount
        ]

        // Delete existing item first
        let statusDelete = SecItemDelete(query as CFDictionary)
        if statusDelete != errSecSuccess && statusDelete != errSecItemNotFound {
            print("Error deleting existing keychain item: \(statusDelete)")
            // Decide if this should be a fatal error for the save operation
        }

        // Add new item
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: anonymousIdAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly // Accessibility level
        ]

        let statusAdd = SecItemAdd(attributes as CFDictionary, nil)
        guard statusAdd == errSecSuccess else {
            print("Error saving to keychain: \(statusAdd)")
            throw KeychainError.saveError(statusAdd)
        }
        print("DEBUG: [KeychainHelper] Successfully saved anonymous ID to Keychain.")
    }

    func getAnonymousId() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: anonymousIdAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: kCFBooleanTrue!
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let id = String(data: data, encoding: .utf8) else {
                throw KeychainError.unexpectedData
            }
            print("DEBUG: [KeychainHelper] Successfully retrieved anonymous ID from Keychain.")
            return id
        case errSecItemNotFound:
            print("DEBUG: [KeychainHelper] Anonymous ID not found in Keychain.")
            return nil // No ID found, this is expected on first launch
        default:
            print("Error loading from keychain: \(status)")
            throw KeychainError.loadError(status)
        }
    }

    func deleteAnonymousId() throws {
         let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: anonymousIdAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
             print("Error deleting anonymous ID from keychain: \(status)")
            throw KeychainError.unhandledError(status: status)
        }
         print("DEBUG: [KeychainHelper] Successfully deleted anonymous ID from Keychain (if it existed).")
    }
} 