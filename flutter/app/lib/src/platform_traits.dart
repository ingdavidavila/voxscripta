import 'dart:io';

import 'package:flutter/foundation.dart';

/// What kind of machine this is, for the places where "native feel" is a
/// behaviour rather than a colour.
///
/// The parity contract (`Docs/PARITY.md`) asks for the same features with each
/// platform's own conventions. Most of that is Material's job. The parts that
/// are not come down to one question — is there a pointer? — because a mouse
/// gets hover, tooltips and right-click, and a finger gets long-press and more
/// generous hit targets.
class PlatformTraits {
  const PlatformTraits._();

  /// Forces [hasPointer] for previews and tests.
  ///
  /// Needed because the only machine available to render on is macOS, which is
  /// the one platform this app will never ship to. Without an override the
  /// phone previews showed desktop affordances at phone size — the right
  /// pixels for the wrong platform, which is worse than no preview at all.
  @visibleForTesting
  static bool? debugPointerOverride;

  static bool get isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  /// Whether a pointer is driving. Decides hover, tooltips and right-click.
  static bool get hasPointer => debugPointerOverride ?? isDesktop;

  /// Why long-press and tooltips cannot both be used on one widget: Flutter
  /// shows a `Tooltip` on long-press when there is no pointer, which is the
  /// same gesture a context menu wants. So touch builds get the menu and
  /// desktop builds get the tooltip, rather than both getting a conflict.
  static bool get usesLongPressForMenu => !hasPointer;

  /// What the file manager is called here, for the reveal action. The SwiftUI
  /// app says "Show in Finder"; saying that on Windows would be nonsense.
  static String get fileManagerName {
    if (Platform.isMacOS) return 'Finder';
    if (Platform.isWindows) return 'File Explorer';
    return 'the file manager';
  }

  /// Opens a folder in the platform's file manager.
  ///
  /// Platform-side on purpose: the engine has no business knowing what a
  /// desktop shell is called, and `Docs/PARITY.md` lists this row as the
  /// interface's own.
  static Future<bool> revealInFileManager(String path) async {
    final (command, arguments) = switch (Platform.operatingSystem) {
      'macos' => ('open', ['-R', path]),
      'windows' => ('explorer', [path]),
      'linux' => ('xdg-open', [path]),
      _ => ('', <String>[]),
    };
    if (command.isEmpty) return false;
    try {
      final result = await Process.run(command, arguments);
      // explorer.exe returns 1 even on success, which is a known quirk rather
      // than a failure, so the exit code is not trusted on Windows.
      return Platform.isWindows || result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }
}
