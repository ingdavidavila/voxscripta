import 'package:voxscripta_engine/voxscripta_engine.dart';

import 'l10n.dart';

/// What the engine said went wrong, in the reader's language.
///
/// The engine cannot translate its own sentences off Apple's platforms, so it
/// reports a stable `code` and the values involved, and the words are written
/// here. A code with no wording yet shows the engine's own sentence: English
/// is a better answer than an empty dialog, and it is what will happen the
/// first time the engine gains a case faster than this table does.
///
/// Numbers arrive as plain digits and are formatted here, in the reader's
/// locale. `invalidArgument` is deliberately not worded: it means the interface
/// handed the engine something it refuses, which is a bug to fix, not a
/// message to make friendly.
String failureText(
  AppLocalizations l10n,
  EngineFailure? failure, {
  required String fallback,
}) {
  if (failure == null) return fallback;
  final d = failure.details;
  String text(String key) => d[key] ?? '';
  int? whole(String key) => int.tryParse(d[key] ?? '');

  final tokens = whole('tokens');
  final limit = whole('limit');
  final found = whole('found');
  final supported = whole('supported');
  final needed = whole('needed');
  final available = whole('available');

  final worded = switch (failure.code) {
    'sourceUnavailable' => l10n.errSourceUnavailable(text('path')),
    'sourceChanged' => l10n.errSourceChanged(text('path')),
    'unsupportedFormat' => l10n.errUnsupportedFormat(text('description')),
    'noAudioTrack' => l10n.errNoAudioTrack(_baseName(text('path'))),
    'unsupportedContainer' =>
      l10n.errUnsupportedContainer(text('fileExtension')),
    'decodingFailed' => l10n.errDecodingFailed(text('reason')),
    'noWordsRecognized' => l10n.errNoWordsRecognized(text('locale')),
    'microphoneDenied' => l10n.errMicrophoneDenied,
    'recordingFailed' => l10n.errRecordingFailed(text('reason')),
    'analysisFailed' => l10n.errAnalysisFailed(text('stage'), text('reason')),
    'noSpeechDetected' => l10n.errNoSpeechDetected,
    'engineUnavailable' =>
      l10n.errEngineUnavailable(text('engine'), text('reason')),
    'localeUnsupported' =>
      l10n.errLocaleUnsupported(text('engine'), text('locale')),
    'transcriptionFailed' =>
      l10n.errTranscriptionFailed(text('chunk'), text('reason')),
    'modelAssetMissing' => l10n.errModelAssetMissing(text('description')),
    'modelUnavailable' =>
      l10n.errModelUnavailable(text('model'), text('reason')),
    'contextWindowExceeded' when tokens != null && limit != null =>
      l10n.errContextWindowExceeded(tokens, limit),
    'validationRejected' => l10n.errValidationRejected(text('reasons')),
    'projectCorrupt' => l10n.errProjectCorrupt(text('reason')),
    'schemaTooNew' when found != null && supported != null =>
      l10n.errSchemaTooNew(found, supported),
    'insufficientDiskSpace' when needed != null && available != null =>
      l10n.errInsufficientDiskSpace(
          formatBytes(needed), formatBytes(available)),
    'ioFailure' => l10n.errIoFailure(text('path'), text('reason')),
    'cancelled' => l10n.errCancelled,
    _ => null,
  };
  if (worded != null) return worded;
  return failure.message.isNotEmpty ? failure.message : fallback;
}

/// A file size the way people read one: 1.4 GB, 480 MB. Decimal units, as the
/// system's own file sizes use, and no locale-specific separators beyond the
/// point, which every supported language can read.
String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit += 1;
  }
  final digits = unit == 0 || value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

String _baseName(String path) {
  final cut = path.lastIndexOf(RegExp(r'[\\/]'));
  return cut < 0 ? path : path.substring(cut + 1);
}

/// The wording of one password requirement, keyed by the engine's stable id so
/// the sentence follows the interface language. An id this table does not know
/// shows the engine's own [PasswordRule.demand].
String passwordRuleText(AppLocalizations l10n, PasswordRule rule) {
  switch (rule.id) {
    case 'length':
      final minimum = int.tryParse(rule.details['minimum'] ?? '');
      if (minimum != null) return l10n.passwordRuleLength(minimum);
    case 'uppercase':
      return l10n.passwordRuleUppercase;
    case 'number':
      return l10n.passwordRuleNumber;
    case 'special':
      return l10n.passwordRuleSpecial;
  }
  return rule.demand;
}
