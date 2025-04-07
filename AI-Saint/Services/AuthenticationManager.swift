import Foundation
import FirebaseAuth
import GoogleSignIn
import AuthenticationServices
import FirebaseCore
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
            
            // Request notification permission after successful sign in
            await requestNotificationPermission()
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
    
    // Helper function to request notification permission
    private func requestNotificationPermission() async {
        print("🔔 [AuthenticationManager] Requesting notification permission")
        await NotificationManager.shared.requestNotificationPermission()
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