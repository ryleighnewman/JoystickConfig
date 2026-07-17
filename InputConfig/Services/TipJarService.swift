import Foundation
import StoreKit
import Accessibility

/// Apple-compliant tip jar built on StoreKit 2.
///
/// Two product families are supported:
///
/// * **Consumable** tips for a one-time thank you. The user can buy any of
///   them any number of times.
/// * **Auto-renewable subscriptions** ("Recurring Tips" group) for users who
///   want to support development every month. Cancellation is handled by the
///   system via the manage-subscriptions sheet.
///
/// All product identifiers below must exist in App Store Connect exactly as
/// written. Subscriptions must all belong to a single group named
/// "Recurring Tips" with monthly duration so the user can switch tiers
/// without ending up with multiple concurrent subscriptions.
@MainActor
final class TipJarService: ObservableObject {
    static let shared = TipJarService()

    /// One-time consumable tip IDs.
    static let consumableProductIDs: [String] = [
        "com.inputconfig.app.tip.small",    // suggested $0.99
        "com.inputconfig.app.tip.med",      // suggested $2.99
        "com.inputconfig.app.tip.large",    // suggested $4.99
        "com.inputconfig.app.tip.generous"  // suggested $9.99
    ]

    /// Monthly auto-renewable tip IDs. All in the "Recurring Tips" group.
    static let subscriptionProductIDs: [String] = [
        "com.inputconfig.app.tip.small.monthly",
        "com.inputconfig.app.tip.medium.monthly",
        "com.inputconfig.app.tip.large.monthly",
        "com.inputconfig.app.tip.generous.monthly"
    ]

    @Published private(set) var consumableProducts: [Product] = []
    @Published private(set) var subscriptionProducts: [Product] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var totalTipsCount: Int = 0
    @Published private(set) var activeSubscription: Product?
    @Published var purchaseInProgress: String? // product ID being purchased

    private var transactionListener: Task<Void, Never>?

    private init() {
        loadTipCount()
        transactionListener = listenForTransactions()
    }

    deinit {
        transactionListener?.cancel()
    }

    // MARK: - Loading

    /// Fetch product metadata from the App Store. Call this when the tip jar
    /// view appears so prices are localized and current.
    func loadProducts() async {
        guard !isLoading else { return }
        isLoading = true
        lastError = nil

        let allIDs = Self.consumableProductIDs + Self.subscriptionProductIDs

        do {
            let fetched = try await Product.products(for: allIDs)
            // Split by type so the view can show one list at a time.
            consumableProducts = fetched
                .filter { $0.type == .consumable }
                .sorted { $0.price < $1.price }
            subscriptionProducts = fetched
                .filter { $0.type == .autoRenewable }
                .sorted { $0.price < $1.price }
        } catch {
            // Swallow load failures silently so the UI just shows the friendly
            // empty state instead of an alarming network-error banner. The
            // underlying error is logged for debugging but never surfaced.
            NSLog("TipJarService: product load failed: \(error.localizedDescription)")
        }

        await refreshActiveSubscription()
        isLoading = false
    }

    // MARK: - Purchase

    /// Begin the purchase flow for the given product. Returns true on success,
    /// false if the user cancelled, and throws on a verification failure.
    @discardableResult
    func purchase(_ product: Product) async throws -> Bool {
        purchaseInProgress = product.id
        defer { purchaseInProgress = nil }

        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await transaction.finish()
            incrementTipCount()
            await refreshActiveSubscription()
            AccessibilityNotification.Announcement("Thank you for your support").post()
            return true

        case .userCancelled:
            return false

        case .pending:
            // Pending transactions resolve later (e.g. parental approval).
            // The transaction listener picks them up.
            return false

        @unknown default:
            return false
        }
    }

    /// Ask StoreKit to re-sync entitlements. Used by the Restore Purchases
    /// button so a previously-active subscription on this Apple ID can be
    /// re-detected after a reinstall.
    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await refreshActiveSubscription()
        } catch {
            lastError = "Could not restore purchases: \(error.localizedDescription)"
        }
    }

    // MARK: - Subscription State

    /// Look up the user's current auto-renewable entitlement, if any, and
    /// match it back to a fetched Product so the UI can show its name and
    /// surface the Manage Subscription button.
    private func refreshActiveSubscription() async {
        var found: Product?
        var entitledID: String?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard transaction.productType == .autoRenewable else { continue }
            entitledID = transaction.productID
            if let match = subscriptionProducts.first(where: { $0.id == transaction.productID }) {
                found = match
                break
            }
        }
        // If a verified subscription entitlement exists but the product list
        // hasn't loaded yet (e.g. the renewal listener fired before
        // loadProducts ran), lazily fetch just that product instead of clearing
        // the active subscription, which would briefly hide the user's plan.
        if found == nil, let entitledID = entitledID {
            found = try? await Product.products(for: [entitledID]).first
        }
        activeSubscription = found
    }

    // MARK: - Transaction Listener

    /// Persistent task that catches purchases approved out of band (StoreKit
    /// recommends every app have one of these running at all times). Also
    /// fires on subscription renewals so the active subscription stays fresh.
    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self = self else { return }
                if case .verified(let transaction) = result {
                    await transaction.finish()
                    // Do NOT count subscription auto-renewals as new tips: they
                    // arrive here every billing period and would inflate the
                    // lifetime count. The initial subscription purchase is
                    // counted in purchase(); only out-of-band one-time
                    // (consumable) tips need crediting from the listener.
                    if transaction.productType != .autoRenewable {
                        await MainActor.run {
                            self.incrementTipCount()
                        }
                    }
                    await self.refreshActiveSubscription()
                }
            }
        }
    }

    /// Throws if the given verification result is not verified.
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let safe):
            return safe
        case .unverified:
            throw TipJarError.unverifiedTransaction
        }
    }

    // MARK: - Local Tip Counter

    private static let tipCountKey = "InputConfig.tipCount"

    private func loadTipCount() {
        totalTipsCount = UserDefaults.standard.integer(forKey: Self.tipCountKey)
    }

    private func incrementTipCount() {
        totalTipsCount += 1
        UserDefaults.standard.set(totalTipsCount, forKey: Self.tipCountKey)
    }
}

enum TipJarError: LocalizedError {
    case unverifiedTransaction

    var errorDescription: String? {
        switch self {
        case .unverifiedTransaction:
            return "The App Store returned an unverified transaction. Tip was not processed."
        }
    }
}
