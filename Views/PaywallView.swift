// What Pro is, and what it is not.
//
// This screen sells an upgrade to an app that records medicine for somebody's
// parent, which puts two constraints on it that an ordinary paywall does not
// have:
//
//  * **It cannot promise safety.** No "never miss a dose", no "peace of mind",
//    no "keep her safe". A paywall that implies the paid tier prevents a
//    missed dose is making a medical claim, and the free tier would be
//    implied to be the unsafe one -- which is exactly backwards from how this
//    product works. What Pro changes is how far back you can look, how many
//    tablets can hang on a wall, and whether the log can be searched.
//  * **It cannot sell membership.** Everyone in the circle is unlimited on
//    every plan, and that has to be on this screen in words. It is the single
//    thing a family most expects to be charged for, and the only thing they
//    would be right to be angry about discovering afterwards.
//
// The prices are StoreKit's. The server deliberately does not send them --
// Apple localizes them, applies the storefront's tax treatment, and knows about
// a sale this screen does not -- so when StoreKit has nothing to say, this
// screen says nothing about price rather than inventing one.

import StoreKit
import SwiftUI

@MainActor
@Observable
final class PaywallModel {
    var products: [ProductOffer] = []
    var current: Entitlement?
    /// Localized prices from StoreKit, keyed by product id. Empty on a runner
    /// with no storefront, which is a state the screen renders rather than
    /// papers over.
    var prices: [String: String] = [:]
    var loading = false
    var busy: String?
    var error: String?
    /// The sentence shown after a purchase the server accepted.
    var confirmed: String?

    private let api: any CareHiveAPI

    init(api: any CareHiveAPI) {
        self.api = api
    }

    var isPro: Bool { current?.isPro ?? false }

    func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let response = try await api.products()
            products = response.products
            current = response.current
            await loadPrices()
        } catch {
            self.error = TodayModel.message(for: error)
        }
    }

    /// StoreKit's side of the same list. Failure is not an error worth
    /// showing: it means this device cannot reach the store right now, and the
    /// screen degrades to naming the plans without a number.
    private func loadPrices() async {
        guard !AppEnvironment.isDemo else { return }
        let ids = products.map(\.id)
        guard !ids.isEmpty else { return }
        guard let loaded = try? await Product.products(for: ids) else { return }
        var out: [String: String] = [:]
        for product in loaded { out[product.id] = product.displayPrice }
        prices = out
    }

    /// Buys one, then hands the receipt to the server.
    ///
    /// The order matters: StoreKit's answer is never treated as the purchase
    /// having succeeded. What the family has paid for is whatever the server
    /// says after it has verified the signature itself -- see `Entitlement`.
    func buy(_ offer: ProductOffer) async {
        busy = offer.id
        error = nil
        defer { busy = nil }
        do {
            guard let product = try await Product.products(for: [offer.id]).first else {
                self.error = "The App Store did not recognise that plan."
                return
            }
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let entitlement = try await api.verifyPurchase(
                    signedTransaction: verification.jwsRepresentation)
                current = entitlement
                confirmed = entitlement.isPro
                    ? "You're on CareHive Pro. It is active on every device you sign in on."
                    : "The purchase went through, but the plan is not active yet."
            case .userCancelled:
                break
            case .pending:
                // Ask-to-buy, or a payment that needs a bank step. Saying
                // "failed" here would be wrong and would make somebody pay
                // twice.
                confirmed = "This purchase is waiting for approval. It will "
                    + "start on its own once it is approved."
            @unknown default:
                break
            }
        } catch {
            self.error = TodayModel.message(for: error)
        }
    }

    /// Restore. Not a convenience: Apple requires it, and on a new phone it is
    /// the only way back to what somebody already paid for.
    func restore() async {
        busy = "restore"
        error = nil
        defer { busy = nil }
        do {
            try await AppStore.sync()
            // Re-verify whatever is now current rather than trusting the sync.
            for await result in Transaction.currentEntitlements {
                guard case .verified = result else { continue }
                let entitlement = try await api.verifyPurchase(
                    signedTransaction: result.jwsRepresentation)
                current = entitlement
                break
            }
            confirmed = current?.isPro == true
                ? "Your CareHive Pro subscription is back."
                : "No subscription was found for this Apple ID."
        } catch {
            self.error = TodayModel.message(for: error)
        }
    }
}

// MARK: - Screen

struct PaywallView: View {
    @State private var model: PaywallModel
    @Environment(\.dismiss) private var dismiss

    init(api: any CareHiveAPI) {
        _model = State(initialValue: PaywallModel(api: api))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    header
                    if model.isPro { currentPlanCard } else { plans }
                    comparison
                    membershipNote
                    legal
                }
                .padding(DS.Space.m)
            }
            .background(DS.Palette.screen)
            .navigationTitle("CareHive Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !model.isPro {
                        Button("Restore") { Task { await model.restore() } }
                            .disabled(model.busy != nil)
                    }
                }
            }
            .task { await model.load() }
            .alert("That didn't work", isPresented: Binding(
                get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK") { model.error = nil }
            } message: {
                Text(model.error ?? "")
            }
        }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("For the family looking after someone")
                .font(.title2.weight(.semibold))
            Text("CareHive is free for the whole circle, forever. Pro is for "
                 + "families who want the whole history, and more than one "
                 + "screen on a wall.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Shown when the plan is already active, instead of a row of buy buttons.
    /// Offering somebody a plan they are on is the fastest way to make them
    /// think they are being charged twice.
    private var currentPlanCard: some View {
        ExplanationCard(
            symbol: "checkmark.seal",
            title: "You're on CareHive Pro",
            message: model.current?.expiresAt.map {
                "Renews on \(WallClock.shortDate($0)). It covers everyone in "
                + "your circle on every device they sign in on."
            } ?? "It covers everyone in your circle on every device they sign "
                + "in on.")
    }

    private var plans: some View {
        VStack(spacing: DS.Space.m) {
            if model.products.isEmpty {
                if model.loading {
                    ProgressView().padding(DS.Space.l)
                } else {
                    Text("Plans are not available right now.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(DS.Space.l)
                }
            } else {
                ForEach(model.products) { offer in
                    PlanButton(
                        offer: offer,
                        price: model.prices[offer.id],
                        busy: model.busy == offer.id,
                        disabled: model.busy != nil
                    ) {
                        Task { await model.buy(offer) }
                    }
                }
            }

            if let confirmed = model.confirmed {
                ExplanationCard(symbol: "info.circle", title: "One moment",
                                message: confirmed)
            }
        }
    }

    /// The one place the two plans are set against each other, and every line
    /// is a limit the server actually enforces -- nothing here is aspirational
    /// copy that the backend would then contradict.
    private var comparison: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A bare two-column table with no headers reads as two numbers,
            // and the left one is the one people assume is the price.
            HStack(spacing: DS.Space.s) {
                Spacer(minLength: 0)
                Text("Free")
                    .frame(width: 86, alignment: .trailing)
                Text("Pro")
                    .frame(width: 86, alignment: .trailing)
            }
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.horizontal, DS.Space.m)
            .padding(.top, DS.Space.m)
            .padding(.bottom, DS.Space.s)

            Divider()

            ComparisonRow(label: "Everyone in the circle", free: "Unlimited",
                          pro: "Unlimited", emphasised: true)
            Divider()
            ComparisonRow(label: "History", free: "30 days", pro: "All of it")
            Divider()
            ComparisonRow(label: "Tablets on a wall", free: "1", pro: "10")
            Divider()
            ComparisonRow(label: "Search the log", free: "No", pro: "Yes")
            Divider()
            ComparisonRow(label: "Photos a month", free: "4", pro: "100")
            Divider()
            ComparisonRow(label: "Supply run-out estimate", free: "At your level",
                          pro: "At this rate")
        }
        .background(DS.Palette.card, in: RoundedRectangle(cornerRadius: 14))
    }

    /// The sentence the whole screen exists to be able to say.
    private var membershipNote: some View {
        ExplanationCard(
            symbol: "person.2",
            title: "Nobody is charged for joining",
            message: "Every brother, sister, neighbour and carer your family "
                + "adds can see today and record a dose. That is free on both "
                + "plans and it stays that way -- paying changes what you can "
                + "look back at, never who is allowed to help.")
    }

    /// Both links, because the App Store description requires them and a
    /// subscription screen without them is rejected before anybody reads it.
    ///
    /// Served by CareHive's own API (see `routers/legal.py` on the server), not
    /// by the developer's other app's site. A reviewer who taps these lands on a
    /// page that names CareHive and describes medication records; pointing them
    /// at a policy written for a different app would be a false statement about
    /// how this app handles health data.
    ///
    /// `AppEnvironment.baseURL` rather than a literal, so the links follow the
    /// server the build actually talks to and cannot drift from it.
    private var legal: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Subscriptions renew automatically unless cancelled at least 24 "
                 + "hours before the period ends. Manage or cancel it in your "
                 + "Apple ID settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: DS.Space.m) {
                Link("Terms of Use", destination: Self.legalURL("terms"))
                Link("Privacy Policy", destination: Self.legalURL("privacy"))
            }
            .font(.footnote)
        }
    }

    private static func legalURL(_ page: String) -> URL {
        AppEnvironment.baseURL.appendingPathComponent(page)
    }
}

// MARK: - Pieces

private struct PlanButton: View {
    let offer: ProductOffer
    let price: String?
    let busy: Bool
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    // No invented number when StoreKit has none. "See the App
                    // Store" is a worse button and a true one.
                    Text(price ?? "Price shown in the App Store")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if busy { ProgressView() }
            }
        }
        .buttonStyle(PrimaryButtonStyle(enabled: !disabled))
        .disabled(disabled)
    }

    /// Derived from the product id's suffix rather than from a second field on
    /// the wire, because the id is the thing App Store Connect and the server
    /// already have to agree on.
    private var title: String {
        if offer.id.hasSuffix(".yearly") { return "Yearly" }
        if offer.id.hasSuffix(".monthly") { return "Monthly" }
        return "CareHive Pro"
    }
}

private struct ComparisonRow: View {
    let label: String
    let free: String
    let pro: String
    /// The row that is the same on both, marked so it reads as a promise
    /// rather than as a column somebody skimmed.
    var emphasised = false

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Text(label)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(free)
                .font(.subheadline.weight(emphasised ? .semibold : .regular))
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .trailing)
            Text(pro)
                .font(.subheadline.weight(.semibold))
                .frame(width: 86, alignment: .trailing)
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s + 2)
    }
}
