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

    // How the name reaches the dialog, which is different on each desktop and
    // only dangerous on two of them.
    //
    // macOS and Windows are handed a *script* — AppleScript for `osascript`,
    // PowerShell for `powershell`. A quote in the name would close a string
    // literal there and the rest would run, so on those two the script text is
    // a constant and the name is read out of the environment.
    //
    // Linux is handed no script. `Process.run` without `runInShell` execs the
    // program directly, so zenity and kdialog receive the name as one element
    // of argv with nothing left to parse it: `evil"; rm -rf ~; ".txt` is an
    // odd file name and nothing more. Searching argv for `rm -rf` there would
    // be searching a string the test itself made by joining the arguments.
    //
    // The desktop is injected because reading the real [Platform] meant each
    // of these could only be checked on the machine it belonged to — which is
    // how the Linux route came to fail on CI while passing on every Mac here.
    const hostile = 'evil"; rm -rf ~; ".txt';

    /// Every command the saver tried, in order. Linux tries two: zenity, and
    /// then kdialog when zenity is not installed, which is what the stand-in
    /// below reports. Both are checked, because either may be the one that
    /// runs on a given machine.
    Future<List<({String command, List<String> args, Map<String, String> env})>>
        ask(Desktop desktop, {String name = hostile}) async {
      final calls =
          <({String command, List<String> args, Map<String, String> env})>[];
      await save(
        DesktopFileSaver(
          fallbackDirectory: directory,
          desktop: desktop,
          runner: (command, args, env) async {
            calls.add((command: command, args: args, env: env));
            return (ran: false, stdout: null);
          },
        ),
        name: name,
      );
      expect(calls, isNotEmpty, reason: '$desktop asked for no dialog');
      return calls;
    }

    test('every desktop is told the name through the environment', () async {
      for (final desktop in Desktop.values) {
        for (final call in await ask(desktop)) {
          expect(call.env['VS_NAME'], hostile, reason: call.command);
          expect(call.env['VS_TITLE'], 'Save', reason: call.command);
        }
      }
    });

    test('the scripted desktops keep the name out of the command', () async {
      for (final desktop in [Desktop.macOS, Desktop.windows]) {
        for (final call in await ask(desktop)) {
          for (final argument in call.args) {
            expect(argument, isNot(contains('evil')), reason: call.command);
            expect(argument, isNot(contains('rm -rf')), reason: call.command);
          }
        }
      }
    });

    test('Linux passes the name as one whole argument, unchanged', () async {
      for (final call in await ask(Desktop.linux)) {
        // One argument carries it, and carries all of it: a name split across
        // two arguments would be a name something had reinterpreted.
        final carrying = call.args.where((a) => a.contains('evil')).toList();
        expect(carrying, hasLength(1), reason: call.command);
        expect(carrying.single, endsWith(hostile), reason: call.command);
      }
    });

    test('a name beginning with a dash cannot be read as an option', () async {
      // kdialog takes the name positionally, so it is the one route where a
      // leading dash matters; zenity's `--filename=` form is safe already.
      final calls = await ask(Desktop.linux, name: '-x.txt');
      final kdialog = calls.firstWhere((c) => c.command == 'kdialog');
      expect(kdialog.args, contains('./-x.txt'));
      expect(kdialog.args, isNot(contains('-x.txt')));
      // An ordinary name is left exactly as it is.
      final plain = await ask(Desktop.linux, name: 'talk.txt');
      expect(plain.firstWhere((c) => c.command == 'kdialog').args,
          contains('talk.txt'));
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
}
