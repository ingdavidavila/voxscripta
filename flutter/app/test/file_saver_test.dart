import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxscripta/src/transcript/file_saver.dart';

/// Saving a transcript.
///
/// The system's dialogs cannot be driven from a test, so each is replaced by a
/// stand-in that answers as the real one does: a chosen path, a cancel, or a
/// tool that is not installed. What is checked is what the app does with each
/// answer, which is the part that is ours.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  final bytes = Uint8List.fromList([104, 105]);
  final sep = Platform.pathSeparator;

  setUp(() => directory = Directory.systemTemp.createTempSync('saver'));
  tearDown(() => directory.deleteSync(recursive: true));

  Future<SaveOutcome> save(DesktopFileSaver saver,
          {String name = 'talk.txt'}) =>
      saver.save(
        suggestedName: name,
        mimeType: 'text/plain',
        bytes: bytes,
        dialogTitle: 'Save',
      );

  group('desktop', () {
    test('writes to the path the dialog returned', () async {
      final target = '${directory.path}${sep}chosen.txt';
      final outcome = await save(DesktopFileSaver(
        runner: (_, _, _) async => (ran: true, stdout: target),
      ));
      expect(outcome, isA<Saved>().having((s) => s.where, 'where', target));
      expect(File(target).readAsBytesSync(), bytes);
    });

    test('a cancelled dialog writes nothing and says nothing', () async {
      final outcome = await save(DesktopFileSaver(
        fallbackDirectory: directory,
        runner: (_, _, _) async => (ran: true, stdout: null),
      ));
      expect(outcome, isA<SaveCancelled>());
      expect(directory.listSync(), isEmpty);
    });

    test('with no dialog installed it writes to the fallback and says where',
        () async {
      final outcome = await save(DesktopFileSaver(
        fallbackDirectory: directory,
        runner: (_, _, _) async => (ran: false, stdout: null),
      ));
      expect(outcome, isA<Saved>());
      expect(File((outcome as Saved).where).readAsBytesSync(), bytes);
    });

    test('the fallback never overwrites a file that is already there',
        () async {
      File('${directory.path}${sep}talk.txt').writeAsStringSync('keep me');
      final outcome = await save(DesktopFileSaver(
        fallbackDirectory: directory,
        runner: (_, _, _) async => (ran: false, stdout: null),
      ));
      expect((outcome as Saved).where, endsWith('talk (2).txt'));
      expect(File('${directory.path}${sep}talk.txt').readAsStringSync(),
          'keep me');
    });

    test('an unwritable path is a failure with a reason, not a crash',
        () async {
      final outcome = await save(DesktopFileSaver(
        runner: (_, _, _) async =>
            (ran: true, stdout: '${directory.path}${sep}no-such${sep}x.txt'),
      ));
      expect(outcome, isA<SaveFailed>());
    });

    test('the name and title go in the environment, not the command', () async {
      Map<String, String>? seen;
      List<String>? args;
      await save(
        DesktopFileSaver(
          fallbackDirectory: directory,
          runner: (_, a, env) async {
            args = a;
            seen = env;
            return (ran: false, stdout: null);
          },
        ),
        name: 'evil"; rm -rf ~; ".txt',
      );
      expect(seen!['VS_NAME'], 'evil"; rm -rf ~; ".txt');
      expect(args!.join(' '), isNot(contains('rm -rf')));
    });
  });

  group('android channel', () {
    const channel = MethodChannel(ChannelFileSaver.channelName);
    void answer(Future<Object?> Function(MethodCall) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, handler);
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
    }

    Future<SaveOutcome> run() => const ChannelFileSaver().save(
          suggestedName: 'talk.srt',
          mimeType: 'application/x-subrip',
          bytes: bytes,
          dialogTitle: 'Save',
        );

    test('sends the name, type and bytes, and reports the document name',
        () async {
      MethodCall? seen;
      answer((call) async {
        seen = call;
        return 'talk.srt';
      });
      final outcome = await run();
      expect(outcome, isA<Saved>().having((s) => s.where, 'where', 'talk.srt'));
      expect(seen!.arguments['mime'], 'application/x-subrip');
      expect(seen!.arguments['bytes'], bytes);
    });

    test('a closed picker is a cancel', () async {
      answer((_) async => null);
      expect(await run(), isA<SaveCancelled>());
    });

    test('a refused write is a failure with the reason', () async {
      answer((_) async =>
          throw PlatformException(code: 'write_failed', message: 'disk full'));
      expect(await run(),
          isA<SaveFailed>().having((s) => s.reason, 'reason', 'disk full'));
    });
  });

  group('names', () {
    test('drops the audio extension and refuses unsafe characters', () {
      expect(safeFileName('Board meeting.m4a', 'txt'), 'Board meeting.txt');
      expect(safeFileName('a/b:c*d', 'md'), 'a_b_c_d.md');
      expect(safeFileName('', 'srt'), 'transcript.srt');
    });

    test('two variants of one transcript never share a name', () {
      expect(safeFileName('jfk.wav', 'txt', variant: 'Clean'),
          'jfk — Clean.txt');
      expect(safeFileName('jfk.wav', 'txt', variant: 'Clean'),
          isNot(safeFileName('jfk.wav', 'txt', variant: 'Verbatim')));
    });
  });
}
