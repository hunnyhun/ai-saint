import Foundation
import FirebaseAuth
import GoogleSignIn
import AuthenticationServices
import FirebaseCore
import FirebaseFunctions
import CryptoKit
import os

// AuthenticationManager: Handles all authentication related operations
@Observable final class AuthenticationManager {
    // MARK: - Properties
    var user: User?
    var errorMessage: String?
    var isAuthenticated: Bool = false
    var isLoading: Bool = false
    
    // MARK: - Singleton
    static let shared = AuthenticationManager()
    private init() {
        setupAuthStateListener()
    }
    
    // MARK: - Auth State
    private func setupAuthStateListener() {
        // Store listener handle to prevent deallocation
        let handle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            DispatchQueue.main.async {
                self?.user = user
                self?.isAuthenticated = user != nil
                print("DEBUG: Auth state changed. User: \(user?.uid ?? "nil")")
            }
        }
        // Store handle if needed for cleanup
        print("DEBUG: Auth state listener setup with handle: \(handle)")
    }
    
    // MARK: - Sign In Methods
    
    // Google Sign In
    func signInWithGoogle() async throws {
        isLoading = true
        defer { isLoading = false }
        
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            print("ERROR: Failed to get clientID")
            throw AuthError.clientIDNotFound
        }
        
        let config = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.configuration = config
        
        // Use UIApplication.shared.connectedScenes with await
        guard let windowScene = await UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = await windowScene.windows.first,
              let rootViewController = await window.rootViewController else {
            print("ERROR: Failed to get root view controller")
            throw AuthError.presentationError
        }
        
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootViewController)
            guard let idToken = result.user.idToken?.tokenString else {
                print("ERROR: Failed to get ID token")
                throw AuthError.tokenError
            }
            
            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: result.user.accessToken.tokenString
            )
            
            let authResult = try await Auth.auth().signIn(with: credential)
            print("DEBUG: Successfully signed in with Google. User: \(authResult.user.uid)")
        } catch {
            print("ERROR: Google sign in error: \(error.localizedDescription)")
            throw error
        }
    }
    
    // Apple Sign In
    func signInWithApple() async throws {
        let nonce = randomNonceString()
        let appleIDProvider = ASAuthorizationAppleIDProvider()
        let request = appleIDProvider.createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)
        
        // Use UIApplication.shared.connectedScenes with await
        guard let windowScene = await UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = await windowScene.windows.first,
              let rootViewController = await window.rootViewController else {
            throw AuthError.presentationError
        }
        
        do {
            let result = try await performAppleSignIn(request, on: rootViewController)
            guard let appleIDCredential = result.credential as? ASAuthorizationAppleIDCredential,
                  let appleIDToken = appleIDCredential.identityToken,
                  let idTokenString = String(data: appleIDToken, encoding: .utf8) else {
                throw AuthError.credentialError
            }
            
            // Fix: Use AuthProviderID.apple
            let credential = OAuthProvider.credential(
                providerID: .apple,
                idToken: idTokenString,
                rawNonce: nonce,
                accessToken: nil
            )
            
            let authResult = try await Auth.auth().signIn(with: credential)
            self.user = authResult.user
            print("DEBUG: Successfully signed in with Apple. User: \(authResult.user.uid)")
        } catch {
            print("DEBUG: Apple sign in error: \(error.localizedDescription)")
            throw error
        }
    }
    
    // Anonymous Sign In (Using Persistent Keychain ID and Custom Tokens - Backend Required)
    func signInAnonymously() async throws {
        isLoading = true
        defer { isLoading = false }

        print("DEBUG: [AuthManager] Attempting sign in with persistent anonymous ID...")

        do {
            var persistentId: String?
            
            // 1. Try to get existing ID from Keychain
            persistentId = try KeychainHelper.shared.getAnonymousId()

            if let existingId = persistentId {
                // 2a. Existing ID found
                print("DEBUG: [AuthManager] Found persistent anonymous ID in Keychain: \(existingId)")
                // Call backend to get custom token for existing persistent ID
                let customToken = try await getCustomTokenFromServer(for: existingId)
                let authResult = try await Auth.auth().signIn(withCustomToken: customToken)
                self.user = authResult.user
                print("DEBUG: [AuthManager] Successfully signed in with custom token for existing ID: \(authResult.user.uid)")

            } else {
                // 2b. No existing ID found - Generate, save, and use a new one
                let newId = UUID().uuidString
                print("DEBUG: [AuthManager] No persistent anonymous ID found. Generating new ID: \(newId)")
                try KeychainHelper.shared.saveAnonymousId(newId)
                print("DEBUG: [AuthManager] Saved new persistent anonymous ID to Keychain.")
                persistentId = newId // Use the new ID for the next step

                // Call backend to get custom token for new persistent ID
                let customToken = try await getCustomTokenFromServer(for: newId)
                let authResult = try await Auth.auth().signIn(withCustomToken: customToken)
                self.user = authResult.user
                print("DEBUG: [AuthManager] Successfully signed in with custom token for NEW ID: \(authResult.user.uid)")

            }

        } catch let keychainError as KeychainError {
            print("ERROR: [AuthManager] Keychain error during anonymous sign in: \(keychainError)")
            // Handle specific keychain errors if needed
            throw keychainError // Re-throw for caller
        } catch {
            print("ERROR: [AuthManager] Unexpected error during anonymous sign in: \(error.localizedDescription)")
            throw error // Re-throw
        }
    }
    
    // Sign Out
    func signOut() throws {
        do {
            try Auth.auth().signOut()
            self.user = nil
            print("DEBUG: Successfully signed out")
        } catch {
            print("ERROR: Sign out error: \(error.localizedDescription)")
            throw error
        }
    }
    
    // Store delegate as a property to prevent deallocation
    private var appleSignInDelegate: AppleSignInDelegate?
    
    @MainActor
    func performAppleSignIn(_ request: ASAuthorizationAppleIDRequest, on controller: UIViewController) async throws -> ASAuthorization {
        return try await withCheckedThrowingContinuation { continuation in
            let authController = ASAuthorizationController(authorizationRequests: [request])
            // Store delegate in property to maintain strong reference
            self.appleSignInDelegate = AppleSignInDelegate(continuation: continuation)
            authController.delegate = self.appleSignInDelegate
            authController.presentationContextProvider = self.appleSignInDelegate
            authController.performRequests()
        }
    }
}

// MARK: - Custom Errors
extension AuthenticationManager {
    enum AuthError: LocalizedError {
        case clientIDNotFound
        case presentationError
        case tokenError
        case credentialError
        
        var errorDescription: String? {
            switch self {
            case .clientIDNotFound:
                return "Failed to get Google client ID"
            case .presentationError:
                return "Unable to present sign-in screen"
            case .tokenError:
                return "Failed to get authentication token"
            case .credentialError:
                return "Invalid credentials provided"
            }
        }
    }
}

// MARK: - Helper Methods
private extension AuthenticationManager {
    /// Calls the backend Cloud Function to get a Firebase custom token for the given persistent anonymous ID.
    /// - Parameter id: The persistent anonymous ID (UUID string).
    /// - Returns: The custom token string.
    /// - Throws: An error if the function call fails or the response is invalid.
    func getCustomTokenFromServer(for id: String) async throws -> String {
        let functions = Functions.functions(region: "us-central1")
        do {
            let result = try await functions.httpsCallable("getCustomAuthTokenForAnonymousId").call(["persistentId": id])
            if let data = result.data as? [String: Any],
               let customToken = data["customToken"] as? String {
                print("DEBUG: [AuthManager] Received custom token from backend for persistentId: \(id)")
                return customToken
            } else {
                print("ERROR: [AuthManager] Malformed response from backend: \(result.data)")
                throw AuthError.tokenError
            }
        } catch {
            print("ERROR: [AuthManager] Failed to get custom token from backend: \(error.localizedDescription)")
            throw error
        }
    }

    // Generate random nonce for Apple Sign In
    func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length
        
        while remainingLength > 0 {
            let randoms: [UInt8] = (0 ..< 16).map { _ in
                var random: UInt8 = 0
                let errorCode = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
                if errorCode != errSecSuccess {
                    fatalError("Unable to generate nonce. SecRandomCopyBytes failed with OSStatus \(errorCode)")
                }
                return random
            }
            
            randoms.forEach { random in
                if remainingLength == 0 { return }
                
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }
        return result
    }
    
    // SHA256 hash for nonce using CryptoKit
    func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        return hashedData.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Apple Sign In Delegate
@MainActor
private class AppleSignInDelegate: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    let continuation: CheckedContinuation<ASAuthorization, Error>
    
    init(continuation: CheckedContinuation<ASAuthorization, Error>) {
        self.continuation = continuation
    }
    
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // Use UIWindowScene.windows instead of UIApplication.shared.windows
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first else {
            fatalError("No window found")
        }
        return window
    }
    
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        continuation.resume(returning: authorization)
    }
    
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation.resume(throwing: error)
    }
} 
