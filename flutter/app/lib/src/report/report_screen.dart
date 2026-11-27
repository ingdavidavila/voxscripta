import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n.dart';
import '../transcript/file_saver.dart';

/// Hands text to whatever the person picks from the system's share sheet.
abstract interface class TextSharer {
  /// False when the system had nothing to hand it to.
  Future<bool> share(String text, {required String subject});
}

/// Android's share sheet, through the same small channel the export uses.
class ChannelTextSharer implements TextSharer {
  const ChannelTextSharer(
      [this._channel = const MethodChannel(ChannelFileSaver.channelName)]);

  final MethodChannel _channel;

  @override
  Future<bool> share(String text, {required String subject}) async {
    try {
      await _channel.invokeMethod<void>(
          'shareText', {'text': text, 'subject': subject});
      return true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

/// A report about something that went wrong, for the person to read and then
/// send, or not.
///
/// The app transmits nothing: there is no network access to transmit with, and
/// the privacy claim rests on that. So the whole text is on screen first, and
/// every way out of here is one the person takes: copy it, save it where they
/// choose, or pick an app from the system's share sheet. The text is the
/// engine's, which is what keeps transcripts and paths out of it.
class ReportScreen extends StatelessWidget {
  const ReportScreen({
    super.key,
    required this.report,
    this.sharer,
    this.saver,
  });

  /// Null when the engine could not produce one.
  final String? report;

  /// The share sheet. Present on Android unless supplied.
  final TextSharer? sharer;

  /// Where "Save" writes. Present on desktops unless supplied.
  final FileSaver? saver;

  static const fileName = 'vox-scripta-report.txt';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final text = report;
    final share = sharer ?? (Platform.isAndroid ? const ChannelTextSharer() : null);
    final save = saver ?? (Platform.isAndroid ? null : DesktopFileSaver());

    return Scaffold(
      appBar: AppBar(title: Text(l10n.reportProblem)),
      body: text == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(l10n.reportUnavailable, textAlign: TextAlign.center),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(l10n.reportExplain,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  if (share != null)
                    FilledButton.icon(
                      icon: const Icon(Icons.share),
                      label: Text(l10n.reportShare),
                      onPressed: () async {
                        final shared = await share.share(text,
                            subject: l10n.reportSubject);
                        if (!shared && context.mounted) {
                          _say(context, context.l10n.reportShareFailed);
                        }
                      },
                    ),
                  if (save != null)
                    FilledButton.icon(
                      icon: const Icon(Icons.save_alt),
                      label: Text(l10n.reportSave),
                      onPressed: () => _save(context, save, text),
                    ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.copy),
                    label: Text(l10n.reportCopy),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: text));
                      if (context.mounted) {
                        _say(context, context.l10n.reportCopied);
                      }
                    },
                  ),
                ]),
                const SizedBox(height: 16),
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      text,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(fontFamily: 'monospace'),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Future<void> _save(BuildContext context, FileSaver save, String text) async {
    final outcome = await save.save(
      suggestedName: fileName,
      mimeType: 'text/plain',
      bytes: utf8.encode(text),
      dialogTitle: context.l10n.reportProblem,
    );
    if (!context.mounted) return;
    switch (outcome) {
      case Saved(:final where):
        _say(context, context.l10n.savedTo(where));
      case SaveFailed(:final reason):
        _say(context, context.l10n.saveFailed(reason));
      case SaveCancelled():
        break;
    }
  }

  static void _say(BuildContext context, String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
}
