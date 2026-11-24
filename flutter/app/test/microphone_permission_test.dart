import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxscripta/src/microphone_permission.dart';
import 'package:voxscripta/src/recording/recording_model.dart';
import 'package:voxscripta_engine/voxscripta_engine.dart';

class _Gate implements MicrophonePermission {
  _Gate(this.answer);
  final MicrophoneAccess answer;
  int asked = 0;

  @override
  Future<MicrophoneAccess> ensure() async {
    asked += 1;
    return answer;
  }
}

class _Source implements RecordingSource {
  int started = 0;

  @override
  String get directory => '/r';

  @override
  Recording start({String? destinationPath}) {
    started += 1;
    throw VoxScriptaException('stub engine reached');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the channel', () {
    const channel = MethodChannel(ChannelMicrophonePermission.channelName);

    void answer(Future<Object?> Function(MethodCall)? handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, handler);
    }

    tearDown(() => answer(null));

    for (final (reply, expected) in [
      ('granted', MicrophoneAccess.granted),
      ('denied', MicrophoneAccess.denied),
      ('blocked', MicrophoneAccess.blocked),
    ]) {
      test('maps "$reply"', () async {
        answer((call) async => reply);
        expect(await const ChannelMicrophonePermission().ensure(), expected);
      });
    }

    test('treats no answer as not permitted', () async {
      answer(null);
      expect(await const ChannelMicrophonePermission().ensure(),
          MicrophoneAccess.denied);
    });

    test('treats an unknown answer as not permitted', () async {
      answer((call) async => 'maybe');
      expect(await const ChannelMicrophonePermission().ensure(),
          MicrophoneAccess.denied);
    });

    test('treats a platform error as not permitted', () async {
      answer((call) async => throw PlatformException(code: 'busy'));
      expect(await const ChannelMicrophonePermission().ensure(),
          MicrophoneAccess.denied);
    });
  });

  group('recording without permission', () {
    test('never reaches the engine when denied, and says why', () async {
      final source = _Source();
      final model = RecordingModel(
          source: source, permission: _Gate(MicrophoneAccess.denied));

      await model.start();

      expect(source.started, 0);
      expect(model.isActive, isFalse);
      expect(model.accessProblem, MicrophoneAccess.denied);
      expect(model.startFailure, isNull);
    });

    test('points to Settings when blocked', () async {
      final source = _Source();
      final model = RecordingModel(
          source: source, permission: _Gate(MicrophoneAccess.blocked));

      await model.start();

      expect(source.started, 0);
      expect(model.accessProblem, MicrophoneAccess.blocked);
    });

    test('goes on to the engine once granted', () async {
      final source = _Source();
      final model = RecordingModel(
          source: source, permission: _Gate(MicrophoneAccess.granted));

      await model.start();

      expect(source.started, 1);
      expect(model.startFailure, 'stub engine reached');
    });
  });
}
