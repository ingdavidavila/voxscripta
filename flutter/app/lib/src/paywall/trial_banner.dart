import 'package:flutter/material.dart';
import 'package:voxscripta_engine/voxscripta_engine.dart';

/// The strip above the library saying where the trial stands.
///
/// Shown during the trial as well as after it. A paywall that appears for the
/// first time on the morning of the fourth day, having said nothing for three,
/// is a bait-and-switch — and it is also the version that gets refunded.
class TrialBanner extends StatelessWidget {
  const TrialBanner({super.key, required this.entitlement, this.onSubscribe});

  final Entitlement entitlement;
  final void Function(BuildContext)? onSubscribe;

  @override
  Widget build(BuildContext context) {
    if (!entitlement.shouldOfferSubscription) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final walled = !entitlement.allowsNewWork;
    final scheme = theme.colorScheme;

    return Material(
      color: walled ? scheme.errorContainer : scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          children: [
            Icon(walled ? Icons.lock_outline : Icons.schedule,
                size: 20,
                color: walled
                    ? scheme.onErrorContainer
                    : scheme.onSecondaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _message(entitlement),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: walled
                      ? scheme.onErrorContainer
                      : scheme.onSecondaryContainer,
                ),
              ),
            ),
            if (onSubscribe case final subscribe?)
              TextButton(
                onPressed: () => subscribe(context),
                child: Text(walled ? 'Subscribe' : 'See plans'),
              ),
          ],
        ),
      ),
    );
  }

  static String _message(Entitlement entitlement) {
    switch (entitlement.state) {
      case EntitlementState.trialing:
        final days = entitlement.trialDaysRemaining ?? 0;
        // Counted in days because that is the unit the trial is sold in.
        // Hours would be more precise and would read as a countdown clock.
        return days == 1
            ? 'Last day of your free trial.'
            : '$days days left in your free trial.';
      case EntitlementState.trialExpired:
        return 'Your ${entitlement.trialDays}-day trial has ended. '
            'Everything already transcribed stays yours.';
      case EntitlementState.subscriptionLapsed:
        return 'Your subscription has lapsed. '
            'Everything already transcribed stays yours.';
      case EntitlementState.subscribed:
        return '';
    }
  }
}
