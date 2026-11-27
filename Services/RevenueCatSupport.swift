import Foundation
import RevenueCat

/// Starts RevenueCat without taking any purchase decision away from the app.
///
/// CareHive's own server verifies every StoreKit transaction's JWS signature
/// and decides whether a plan is active; that stays exactly as it is. RC is
/// configured here only so it observes the install and the StoreKit 2
/// transactions the app already makes, which is what puts sales and new
/// customers on its dashboard.
///
/// The key is empty in local and screenshot builds, so this is a no-op there
/// and a demo run never creates a customer.
enum RevenueCatSupport {

    private static let configuredKey = "RevenueCatAPIKey"

    static func start() {
        let raw = Bundle.main.object(forInfoDictionaryKey: configuredKey) as? String ?? ""
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Xcode leaves the literal $(REVENUECAT_API_KEY) in place when the
        // build setting is empty. Treat that as "not configured".
        guard !key.isEmpty, !key.hasPrefix("$(") else { return }
        #if DEBUG
        Purchases.logLevel = .debug
        #endif
        Purchases.configure(withAPIKey: key)
    }
}
