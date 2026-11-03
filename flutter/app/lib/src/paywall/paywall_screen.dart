import 'package:flutter/material.dart';
import 'package:voxscripta_engine/voxscripta_engine.dart';

import 'subscription_service.dart';

/// Where the subscription is sold.
///
/// The disclosures on this screen are not decoration. App Store Review
/// Guideline 3.1.2 requires the paywall itself to carry the subscription's
/// name, its length, its price, and links to the Terms of Use and the Privacy
/// Policy — which is why [SubscriptionService] makes those two links required
/// fields rather than optional ones, and why the prices are strings the store
/// formatted rather than numbers formatted here.
///
/// It also says, plainly, what is *not* locked. A user who hits a wall assumes
/// the worst about their recordings, and in this app the worst is not true:
/// the audio is untouched on their own disk, and every transcript already made
/// stays readable and exportable.
class PaywallScreen extends StatefulWidget {
  const PaywallScreen({
    super.key,
    required this.entitlement,
    this.service,
    this.onSubscribed,
    this.onOpenLink,
  });

  final Entitlement entitlement;

  /// Null when this build has no store wired, which the screen then says
  /// rather than showing buttons that cannot work.
  final SubscriptionService? service;

  final void Function(BuildContext)? onSubscribed;

  /// Opens one of the required legal links. Injected so the screen needs no
  /// url_launcher to be testable.
  final void Function(Uri)? onOpenLink;

  @override
  State<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends State<PaywallScreen> {
  List<SubscriptionProduct>? _products;
  String? _banner;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final service = widget.service;
    if (service == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final products = await service.products();
      if (mounted) {
        setState(() {
          _products = products;
          _loading = false;
        });
      }
    } on SubscriptionException catch (failure) {
      if (mounted) {
        setState(() {
          _banner = failure.message;
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Subscribe'),
        actions: [
          if (widget.service case final service?)
            TextButton(
              onPressed: _busy ? null : () => _restore(service),
              child: const Text('Restore'),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          Text(_headline(widget.entitlement), style: theme.textTheme.headlineSmall),
          const SizedBox(height: 12),
          Text(
            'Vox Scripta transcribes on this machine. Nothing is uploaded, '
            'nothing is sent to a service, and none of that changes with a '
            'subscription — what it pays for is the work of making it.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          const _WhatYouKeep(),
          const SizedBox(height: 24),
          if (_banner case final message?) ...[
            _Banner(message: message),
            const SizedBox(height: 16),
          ],
          if (_loading)
            const Center(child: Padding(
                padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
          else if (widget.service == null)
            const _NoStoreWired()
          else
            ..._plans(),
          const SizedBox(height: 24),
          if (widget.service case final service?) _Disclosure(
            service: service,
            onOpenLink: widget.onOpenLink,
          ),
        ],
      ),
    );
  }

  List<Widget> _plans() {
    final products = _products ?? const [];
    if (products.isEmpty) {
      return [
        Text('No plans came back from the store.',
            style: Theme.of(context).textTheme.bodyMedium),
      ];
    }
    return [
      for (final product in products) ...[
        _PlanCard(
          product: product,
          enabled: !_busy,
          onChoose: () => _purchase(product),
        ),
        const SizedBox(height: 12),
      ],
    ];
  }

  static String _headline(Entitlement entitlement) => switch (entitlement.state) {
        EntitlementState.trialing =>
          'Keep going after your trial',
        EntitlementState.trialExpired =>
          'Your ${entitlement.trialDays}-day trial has ended',
        EntitlementState.subscriptionLapsed => 'Your subscription has lapsed',
        EntitlementState.subscribed => 'You are subscribed',
      };

  Future<void> _purchase(SubscriptionProduct product) async {
    final service = widget.service;
    if (service == null) return;
    setState(() {
      _busy = true;
      _banner = null;
    });
    try {
      await service.purchase(product);
      if (!mounted) return;
      final done = widget.onSubscribed;
      if (done != null) {
        done(context);
      } else {
        Navigator.of(context).pop();
      }
    } on SubscriptionException catch (failure) {
      // Backing out of the store's own sheet is not an error and must not be
      // reported as one.
      if (mounted && !failure.wasCancelled) {
        setState(() => _banner = failure.message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore(SubscriptionService service) async {
    setState(() {
      _busy = true;
      _banner = null;
    });
    try {
      await service.restore();
      if (!mounted) return;
      final done = widget.onSubscribed;
      if (done != null) {
        done(context);
      } else {
        Navigator.of(context).pop();
      }
    } on SubscriptionException catch (failure) {
      if (mounted && !failure.wasCancelled) {
        setState(() => _banner = failure.message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// What the wall does not touch.
///
/// Spelled out because the honest answer is reassuring and the assumed answer
/// is not: people expect a paywall to hold their files.
class _WhatYouKeep extends StatelessWidget {
  const _WhatYouKeep();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('What stays yours either way',
              style: theme.textTheme.titleSmall),
          const SizedBox(height: 10),
          for (final line in const [
            'Every recording you imported — untouched, where you put it.',
            'Every transcript already made — readable, copyable, exportable.',
            'Every export format: txt, md, docx, srt, vtt.',
            'Your projects folder, on your own disk.',
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.check, size: 16, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text(line, style: theme.textTheme.bodySmall)),
                ],
              ),
            ),
          const SizedBox(height: 4),
          Text('A subscription unlocks new transcriptions and recording.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.product,
    required this.enabled,
    required this.onChoose,
  });

  final SubscriptionProduct product;
  final bool enabled;
  final VoidCallback onChoose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: enabled ? onChoose : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(product.title, style: theme.textTheme.titleMedium),
                        if (product.savingNote case final note?) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(note,
                                style: theme.textTheme.labelSmall?.copyWith(
                                    color:
                                        theme.colorScheme.onPrimaryContainer)),
                          ),
                        ],
                      ],
                    ),
                    if (product.priceDetail case final detail?) ...[
                      const SizedBox(height: 4),
                      Text(detail,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(product.price, style: theme.textTheme.titleMedium),
            ],
          ),
        ),
      ),
    );
  }
}

/// The small print Guideline 3.1.2 requires on this screen.
class _Disclosure extends StatelessWidget {
  const _Disclosure({required this.service, this.onOpenLink});

  final SubscriptionService service;
  final void Function(Uri)? onOpenLink;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Subscriptions renew automatically at the price shown until '
          'cancelled. Cancel any time; the subscription runs to the end of '
          'the period already paid for.',
          style: style,
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 16,
          children: [
            _Link(
              label: 'Terms of Use',
              uri: service.termsOfUse,
              onOpenLink: onOpenLink,
            ),
            _Link(
              label: 'Privacy Policy',
              uri: service.privacyPolicy,
              onOpenLink: onOpenLink,
            ),
            if (service.managementPage case final page?)
              _Link(
                label: 'Manage subscription',
                uri: page,
                onOpenLink: onOpenLink,
              ),
          ],
        ),
      ],
    );
  }
}

class _Link extends StatelessWidget {
  const _Link({required this.label, required this.uri, this.onOpenLink});

  final String label;
  final Uri uri;
  final void Function(Uri)? onOpenLink;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      style: TextButton.styleFrom(
        padding: EdgeInsets.zero,
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: onOpenLink == null ? null : () => onOpenLink!(uri),
      child: Text(label),
    );
  }
}

/// Shown when this build has no store wired.
///
/// It says so, rather than showing a Subscribe button that throws. The engine
/// still enforces the wall, so this state is a real dead end and is described
/// as one — which is the point: it is visible rather than discovered.
class _NoStoreWired extends StatelessWidget {
  const _NoStoreWired();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.storefront_outlined,
                  size: 20, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Text('No store is connected in this build',
                  style: theme.textTheme.titleSmall),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Subscriptions are sold through the App Store on Apple devices '
            'and Google Play on Android, and neither is wired up yet, so '
            'there is nothing to buy here. This build cannot start new '
            'transcriptions once the trial ends.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(message,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onErrorContainer)),
    );
  }
}
