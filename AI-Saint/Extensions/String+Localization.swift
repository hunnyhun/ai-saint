import Foundation

// MARK: - String Localization Extension
extension String {
    // Returns localized string using self as key
    var localized: String {
        // Rule: Always add debug logs
        let localizedString = NSLocalizedString(self, comment: "")
        if localizedString == self {
            print("⚠️ [Localization] Missing translation for key: \(self)")
        }
        return localizedString
    }
    
    // Returns localized string with format arguments
    func localized(_ args: CVarArg...) -> String {
        let localizedString = NSLocalizedString(self, comment: "")
        if localizedString == self {
            // Rule: Always add debug logs
            print("⚠️ [Localization] Missing translation for key: \(self)")
        }
        return String(format: localizedString, arguments: args)
    }
} 