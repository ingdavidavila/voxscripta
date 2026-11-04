import SwiftUI
import VoxScriptaCore

/// Where the subscription is sold.
///
/// The small print is not decoration. Review Guideline 3.1.2 requires this
/// screen to carry the subscription's name, its length, its price, and links
/// to the Terms of Use and the Privacy Policy — which is why
/// ``SubscriptionService`` makes those two links required, and why the prices
/// are strings the store formatted rather than numbers formatted here.
///
/// It also says what is *not* locked, because somebody who hits a paywall
/// assumes their recordings are behind it, and in this app they are not.
struct PaywallView: View {
    let model: EntitlementModel
    var onSubscribed: () -> Void = {}

    @State private var products: [SubscriptionProduct] = []
    @State private var banner: String?
    @State private var isLoading = true
    @State private var isBusy = false
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Text(headline).font(.title3.weight(.semibold))
                Text(Strings.paywallPitch)
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                Label(Strings.keepRecordings, systemImage: "checkmark")
                Label(Strings.keepTranscripts, systemImage: "checkmark")
                Label(Strings.keepFormats, systemImage: "checkmark")
                Label(Strings.keepFolder, systemImage: "checkmark")
            } header: {
                Text(Strings.whatStaysYours)
            } footer: {
                Text(Strings.unlocksWhat)
            }

            if let banner {
                Section { AuthBanner(message: banner) }
            }

            if isLoading {
                Section { ProgressView() }
            } else if model.service == nil {
                Section(Strings.noStoreWired) {
                    Text(Strings.noStoreWiredBody).font(.callout)
                }
            } else if products.isEmpty {
                Section { Text(Strings.noPlansReturned).font(.callout) }
            } else {
                Section {
                    ForEach(products) { product in
                        PlanRow(product: product, isBusy: isBusy) { buy(product) }
                    }
                }
            }

            if let service = model.service {
                Section {
                    Text(Strings.renewalTerms)
                        .font(.caption).foregroundStyle(.secondary)
                    // Both links, on this screen. A missing one is a
                    // rejection, and a silent one.
                    Link(Strings.termsOfUse, destination: service.termsOfUse)
                    Link(Strings.privacyPolicyLink, destination: service.privacyPolicy)
                    if let page = service.managementPage {
                        Link(Strings.manageSubscription, destination: page)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Strings.subscribe)
        .toolbar {
            if model.service != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Strings.restorePurchase) { restore() }
                        .disabled(isBusy)
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button(Strings.done) { dismiss() }.disabled(isBusy)
            }
        }
        .task { await load() }
    }

    private var headline: LocalizedStringKey {
        switch model.state {
        case .trialing: Strings.keepGoing
        case .trialExpired: Strings.trialEndedTitle
        case .subscriptionLapsed: Strings.lapsedTitle
        case .subscribed: Strings.subscribedTitle
        }
    }

    private func load() async {
        guard let service = model.service else {
            isLoading = false
            return
        }
        do {
            products = try await service.products()
        } catch let error as SubscriptionError {
            banner = error.message
        } catch {
            banner = error.localizedDescription
        }
        isLoading = false
    }

    private func buy(_ product: SubscriptionProduct) {
        guard let service = model.service else { return }
        isBusy = true
        banner = nil
        Task {
            defer { isBusy = false }
            do {
                try await service.purchase(product)
                model.refresh()
                onSubscribed()
                dismiss()
            } catch let error as SubscriptionError {
                // Backing out of the App Store sheet is not a problem and
                // must not be shown as one.
                if !error.wasCancelled { banner = error.message }
            } catch {
                banner = error.localizedDescription
            }
        }
    }

    private func restore() {
        guard let service = model.service else { return }
        isBusy = true
        banner = nil
        Task {
            defer { isBusy = false }
            do {
                try await service.restore()
                model.refresh()
                onSubscribed()
                dismiss()
            } catch let error as SubscriptionError {
                if !error.wasCancelled { banner = error.message }
            } catch {
                banner = error.localizedDescription
            }
        }
    }
}

private struct PlanRow: View {
    let product: SubscriptionProduct
    let isBusy: Bool
    let onChoose: () -> Void

    var body: some View {
        Button(action: onChoose) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(product.title).font(.headline)
                        if let note = product.savingNote {
                            Text(note)
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.18),
                                            in: Capsule())
                        }
                    }
                    if let detail = product.priceDetail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(product.price).font(.headline)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }
}
