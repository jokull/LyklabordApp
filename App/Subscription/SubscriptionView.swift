//
//  SubscriptionView.swift
//  BetterKeyboard
//
//  The Lyklaborð+ paywall sheet. Honest open-core framing: the base
//  keyboard is free forever; the subscription unlocks the PERSONAL layer
//  (personal vocabulary · typo learning · iCloud sync). Price always comes
//  from StoreKit (`Product.displayPrice` — storefront/locale dependent,
//  never hardcoded), and the sheet carries the App Review-required
//  affordances: restore purchases + Terms (Apple standard EULA) + Privacy
//  Policy links.
//

import StoreKit
import SwiftUI

struct SubscriptionView: View {
    @State private var showingRedeemSheet = false
    @Environment(SubscriptionManager.self) private var subscriptions
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    featureList
                    purchaseArea
                    legalFooter
                }
                .padding()
            }
            .navigationTitle(Strings.Plus.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Strings.Plus.closeButton) { dismiss() }
                }
            }
            .task {
                await subscriptions.loadProductIfNeeded()
            }
        }
        .presentationDetents([.large, .medium])
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Strings.Plus.paywallTagline)
                .font(.title3.bold())
            Text(Strings.Plus.paywallIntro)
                .foregroundStyle(.secondary)
        }
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 16) {
            featureRow(
                systemImage: "character.book.closed",
                title: Strings.Plus.featureVocabTitle,
                detail: Strings.Plus.featureVocabDetail
            )
            featureRow(
                systemImage: "hand.point.up.left",
                title: Strings.Plus.featureTouchTitle,
                detail: Strings.Plus.featureTouchDetail
            )
            featureRow(
                systemImage: "icloud",
                title: Strings.Plus.featureSyncTitle,
                detail: Strings.Plus.featureSyncDetail
            )
        }
    }

    private func featureRow(systemImage: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Decorative — without this VoiceOver reads the SF Symbol's
            // English description ("character book closed") before each
            // Icelandic feature row.
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .font(.title3)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).bold()
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var purchaseArea: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .entitled = subscriptions.status {
                // Already subscribed (sheet reached from a stale surface, or
                // the purchase just completed): thank, don't sell.
                VStack(alignment: .leading, spacing: 6) {
                    Label(Strings.Plus.thanksTitle, systemImage: "checkmark.seal.fill")
                        .font(.headline)
                    Text(Strings.Plus.thanksBody)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    Task { await subscriptions.purchase() }
                } label: {
                    Group {
                        if subscriptions.isPurchasing {
                            ProgressView()
                        } else if let product = subscriptions.product {
                            // Price from StoreKit — never hardcoded.
                            Text(Strings.Plus.subscribeButton(product.displayPrice))
                        } else {
                            Text(Strings.Plus.subscribeButtonNoPrice)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(subscriptions.isPurchasing || subscriptions.product == nil)

                if subscriptions.product == nil {
                    Text(Strings.Plus.priceLoading)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if subscriptions.hasPendingPurchase {
                    Label(Strings.Plus.purchasePending, systemImage: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button(Strings.Plus.restoreButton) {
                Task { await subscriptions.restorePurchases() }
            }
            .font(.callout)

            Button(Strings.Plus.redeemButton) {
                showingRedeemSheet = true
            }
            .font(.callout)
            .offerCodeRedemption(isPresented: $showingRedeemSheet)

            if let error = subscriptions.lastActionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var legalFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Strings.Plus.legalFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Link(
                    Strings.Plus.termsLinkTitle,
                    destination: SubscriptionManager.standardEULAURL
                )
                if let privacy = URL(string: Strings.Links.privacyPolicy) {
                    Link(Strings.Plus.privacyLinkTitle, destination: privacy)
                }
            }
            .font(.caption)
        }
    }
}

#Preview {
    SubscriptionView()
        .environment(SubscriptionManager())
}
