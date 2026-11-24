import 'package:flutter/widgets.dart';

import '../l10n/app_localizations.dart';

export '../l10n/app_localizations.dart';

/// The app's translated text, as `context.l10n.something`.
///
/// Falls back to English when no localization delegate is installed above the
/// widget, which is the case in a widget test that builds a bare `MaterialApp`.
/// In the running app the delegates are always installed (see main.dart), so
/// the fallback only ever applies to tests, and it means they keep asserting on
/// the same English words without each one learning about delegates.
extension AppL10n on BuildContext {
  AppLocalizations get l10n =>
      AppLocalizations.of(this) ?? lookupAppLocalizations(const Locale('en'));
}
