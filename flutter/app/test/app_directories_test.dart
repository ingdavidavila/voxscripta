import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxscripta/src/app_directories.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AppDirectories.channelName);

  void answer(Future<Object?> Function(MethodCall call)? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  tearDown(() => answer(null));

  test('asks for getPaths and returns both directories', () async {
    String? asked;
    answer((call) async {
      asked = call.method;
      return {'files': '/data/user/0/app/files', 'cache': '/data/user/0/app/cache'};
    });

    final directories = await AppDirectories.fromChannel(channel);

    expect(asked, 'getPaths');
    expect(directories.files, '/data/user/0/app/files');
    expect(directories.cache, '/data/user/0/app/cache');
  });

  test('says so when the host does not answer on the channel', () async {
    answer(null);
    expect(AppDirectories.fromChannel(channel),
        throwsA(isA<AppDirectoriesException>()));
  });

  test('says so when the host reports an error', () async {
    answer((call) async => throw PlatformException(code: 'x', message: 'boom'));
    expect(
      AppDirectories.fromChannel(channel),
      throwsA(isA<AppDirectoriesException>()
          .having((e) => e.message, 'message', contains('boom'))),
    );
  });

  test('refuses an answer missing a directory rather than guessing one', () async {
    answer((call) async => {'files': '/data/files'});
    expect(AppDirectories.fromChannel(channel),
        throwsA(isA<AppDirectoriesException>()));
  });

  test('refuses an empty directory', () async {
    answer((call) async => {'files': '', 'cache': '/c'});
    expect(AppDirectories.fromChannel(channel),
        throwsA(isA<AppDirectoriesException>()));
  });
}
