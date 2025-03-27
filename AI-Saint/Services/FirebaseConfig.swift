import Foundation
import FirebaseCore

class FirebaseConfig {
    static func configure() {
        print("[Firebase] Configuring Firebase")
        FirebaseApp.configure()
    }
} 