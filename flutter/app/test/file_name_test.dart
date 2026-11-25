import 'package:flutter_test/flutter_test.dart';
import 'package:voxscripta/main.dart';

void main() {
  test('on Windows either separator ends a directory', () {
    expect(fileNameOf(r'C:\Users\me\jfk.wav', windows: true), 'jfk.wav');
    expect(fileNameOf('C:/Users/me/jfk.wav', windows: true), 'jfk.wav');
    expect(fileNameOf('jfk.wav', windows: true), 'jfk.wav');
  });

  test('elsewhere a backslash belongs to the file name', () {
    // Legal in a macOS or Linux file name; splitting on it would truncate the
    // name and make the truncated half the project's name.
    expect(fileNameOf(r'/home/me/my\recording.m4a', windows: false),
        r'my\recording.m4a');
    expect(fileNameOf('/home/me/jfk.wav', windows: false), 'jfk.wav');
    expect(fileNameOf('jfk.wav', windows: false), 'jfk.wav');
  });
}
