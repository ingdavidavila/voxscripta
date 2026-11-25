import 'package:flutter_test/flutter_test.dart';
import 'package:voxscripta/src/import/file_chooser.dart';

void main() {
  test('Linux offers the dialog only when zenity or kdialog is installed', () {
    bool only(String file) => file == '/usr/bin/zenity';
    expect(
        FileChooser.linuxDialogInstalled(
            path: '/bin:/usr/bin', exists: only),
        isTrue);
    expect(
        FileChooser.linuxDialogInstalled(
            path: '/usr/bin/kdialog-less:/bin', exists: only),
        isFalse);
    expect(
        FileChooser.linuxDialogInstalled(
            path: '/opt/kde/bin', exists: (f) => f == '/opt/kde/bin/kdialog'),
        isTrue);
    expect(FileChooser.linuxDialogInstalled(path: '', exists: (_) => true),
        isFalse);
  });
}
