import SwiftUI
import VoxScriptaCore

/// The strip saying where the trial stands.
///
/// Shown from the first day, not only after the wall goes up. A paywall that
/// says nothing for three days and then appears is a bait-and-switch, and it
/// is also the version that gets refunded.
struct TrialBanner: View {
    let model: EntitlementModel
    var onSubscribe: () -> Void

    var body: some View {
        if model.shouldOfferSubscription {
            HStack(spacing: 10) {
                Image(systemName: model.allowsNewWork ? "clock" : "lock")
                    .foregroundStyle(model.allowsNewWork ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                Text(message)
                    .font(.callout)
                Spacer(minLength: 8)
                Button(model.allowsNewWork ? Strings.seePlans : Strings.subscribe) {
                    onSubscribe()
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(model.allowsNewWork
                        ? Color.secondary.opacity(0.10)
                        : Color.red.opacity(0.12))
        }
    }

    private var message: LocalizedStringKey {
        switch model.state {
        case .trialing:
            // Counted in days because that is the unit the trial is sold in.
            // Hours would be more precise and would read as a countdown.
            let days = model.trialDaysRemaining ?? 0
            return days == 1 ? Strings.lastDayOfTrial : Strings.trialDaysLeft(days)
        case .trialExpired:
            return Strings.trialEndedShort
        case .subscriptionLapsed:
            return Strings.lapsedShort
        case .subscribed:
            return ""
        }
    }
}
