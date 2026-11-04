import 'package:voxscripta_engine/voxscripta_engine.dart';

/// The words the SwiftUI app uses, so the two interfaces say the same things.
///
/// Copied rather than invented. These are user-facing explanations of what the
/// engine did, and two interfaces describing one stage differently is the same
/// drift as two interfaces computing one number differently — just harder to
/// notice. If any of this should change it changes in `Strings.swift` and then
/// here.
class Wording {
  const Wording._();

  static String variantName(TranscriptVariant variant) => switch (variant) {
        TranscriptVariant.verbatim => 'Verbatim',
        TranscriptVariant.clean => 'Clean',
        TranscriptVariant.polished => 'Polished',
      };

  static String variantExplanation(TranscriptVariant variant) => switch (variant) {
        TranscriptVariant.verbatim =>
          'Exactly what was said, including hesitations.',
        TranscriptVariant.clean =>
          'Tidied by fixed rules. No language model was involved.',
        TranscriptVariant.polished =>
          'Rewritten for readability, checked against the original.',
      };

  static String formatName(ExportFormat format) => switch (format) {
        ExportFormat.plainText => 'Plain Text (.txt)',
        ExportFormat.markdown => 'Markdown (.md)',
        ExportFormat.word => 'Word (.docx)',
        ExportFormat.subRip => 'Subtitles (.srt)',
        ExportFormat.webVTT => 'Web Captions (.vtt)',
      };

  static String formatExplanation(ExportFormat format) => switch (format) {
        ExportFormat.plainText => 'Just the words, in a file any editor can open.',
        ExportFormat.markdown =>
          'Words with light formatting, for notes and documentation.',
        ExportFormat.word => 'A Word document, for sharing and further editing.',
        ExportFormat.subRip =>
          'Timed subtitles, the format most video editors expect.',
        ExportFormat.webVTT => 'Timed captions for the web.',
      };

  static String dispositionName(PolishDisposition disposition) =>
      switch (disposition) {
        PolishDisposition.accepted => 'Accepted',
        PolishDisposition.acceptedAfterRetry => 'Accepted after a retry',
        PolishDisposition.fellBackToClean => 'Kept the clean text',
        PolishDisposition.modelFailed => 'Model failed — kept the clean text',
        PolishDisposition.unknown => 'Unknown',
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
