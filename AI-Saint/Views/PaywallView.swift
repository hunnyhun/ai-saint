import SwiftUI
import RevenueCat
import RevenueCatUI

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        PaywallViewControllerRepresentable()
            .ignoresSafeArea()
    }
}

struct PaywallViewControllerRepresentable: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    
    func makeUIViewController(context: Context) -> PaywallViewController {
        print("DEBUG: Creating PaywallViewController...")
        let viewController = PaywallViewController()
        viewController.delegate = context.coordinator
        return viewController
    }
    
    func updateUIViewController(_ uiViewController: PaywallViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    class Coordinator: NSObject, PaywallViewControllerDelegate {
        var parent: PaywallViewControllerRepresentable
        
        init(parent: PaywallViewControllerRepresentable) {
            self.parent = parent
        }
        
        func paywallViewController(_ controller: PaywallViewController, didFinishPurchasingWith customerInfo: CustomerInfo) {
            print("DEBUG: Purchase completed successfully!")
            print("DEBUG: Customer Info - \(customerInfo)")
            parent.dismiss()
        }
        
        func paywallViewController(_ controller: PaywallViewController, didFinishRestoringWith customerInfo: CustomerInfo) {
            print("DEBUG: Purchases restored successfully!")
            print("DEBUG: Customer Info - \(customerInfo)")
            parent.dismiss()
        }
        
        func paywallViewControllerDidClose(_ controller: PaywallViewController) {
            parent.dismiss()
        }
    }
}
