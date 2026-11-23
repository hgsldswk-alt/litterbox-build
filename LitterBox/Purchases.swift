import Foundation
import StoreKit

enum PurchaseError: Error, Equatable { case unavailable, unverified, pending }

enum Purchases {
    static let proID = "com.hgsldswk.litterboxtracker.pro"
    static let trialID = "com.hgsldswk.litterboxtracker.trial"

    static func products() async throws -> [Product] {
        guard !Launch.uiTesting, !Launch.isFree else { return [] }
        return try await Product.products(for: [proID, trialID])
    }

    static func entitlements() async -> (purchased: Bool, trial: Date?) {
        var bought = false
        var trial: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil else { continue }
            if transaction.productID == proID { bought = true }
            if transaction.productID == trialID { trial = transaction.originalPurchaseDate }
        }
        return (bought, trial)
    }

    static func buy(_ product: Product) async throws -> Transaction? {
        switch try await product.purchase() {
        case .success(.verified(let transaction)): return transaction
        case .success(.unverified(_, _)): throw PurchaseError.unverified
        case .pending: throw PurchaseError.pending
        case .userCancelled: return nil
        @unknown default: throw PurchaseError.unavailable
        }
    }
}
