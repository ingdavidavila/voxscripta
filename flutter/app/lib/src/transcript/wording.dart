import 'package:voxscripta_engine/voxscripta_engine.dart';

import '../l10n.dart';

/// The words the SwiftUI app uses, so the two interfaces say the same things.
///
/// Copied rather than invented. These are user-facing explanations of what the
/// engine did, and two interfaces describing one stage differently is the same
/// drift as two interfaces computing one number differently — just harder to
/// notice. If any of this should change it changes in `Strings.swift` and then
/// here.
///
/// Each method takes the translated strings, so the same wording is available in
/// every language the interface supports and no screen carries its own copy.
class Wording {
  const Wording._();

  static String variantName(AppLocalizations l10n, TranscriptVariant variant) =>
      switch (variant) {
        TranscriptVariant.verbatim => l10n.variantVerbatim,
        TranscriptVariant.clean => l10n.variantClean,
        TranscriptVariant.polished => l10n.variantPolished,
      };

  static String variantExplanation(
          AppLocalizations l10n, TranscriptVariant variant) =>
      switch (variant) {
        TranscriptVariant.verbatim => l10n.variantVerbatimExplained,
        TranscriptVariant.clean => l10n.variantCleanExplained,
        TranscriptVariant.polished => l10n.variantPolishedExplained,
      };

  static String formatName(AppLocalizations l10n, ExportFormat format) =>
      switch (format) {
        ExportFormat.plainText => l10n.formatPlainText,
        ExportFormat.markdown => l10n.formatMarkdown,
        ExportFormat.word => l10n.formatWord,
        ExportFormat.subRip => l10n.formatSubRip,
        ExportFormat.webVTT => l10n.formatWebVTT,
      };

  static String formatExplanation(AppLocalizations l10n, ExportFormat format) =>
      switch (format) {
        ExportFormat.plainText => l10n.formatPlainTextExplained,
        ExportFormat.markdown => l10n.formatMarkdownExplained,
        ExportFormat.word => l10n.formatWordExplained,
        ExportFormat.subRip => l10n.formatSubRipExplained,
        ExportFormat.webVTT => l10n.formatWebVTTExplained,
      };

  static String dispositionName(
          AppLocalizations l10n, PolishDisposition disposition) =>
      switch (disposition) {
        PolishDisposition.accepted => l10n.dispositionAccepted,
        PolishDisposition.acceptedAfterRetry => l10n.dispositionAcceptedAfterRetry,
        PolishDisposition.fellBackToClean => l10n.dispositionFellBackToClean,
        PolishDisposition.modelFailed => l10n.dispositionModelFailed,
        PolishDisposition.unknown => l10n.dispositionUnknown,
      };

  /// Which formats a variant can be written as.
  ///
  /// Subtitles need timing, and the polished variant drops word timings
  /// because its text no longer matches the spoken words — the engine's
  /// `Exporters.available(for:)` makes the same judgement from the transcript
  /// itself. Here it is made from the variant, which is the only thing the
  /// screen has, and is why the menu may offer a format the engine then
  /// refuses: that refusal is shown rather than hidden.
  static List<ExportFormat> formatsFor(TranscriptVariant variant) =>
      ExportFormat.values;
}
