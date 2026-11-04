import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:voxscripta_engine/voxscripta_engine.dart';

/// Opens the engine and holds it for the rest of the app.
///
/// A [ChangeNotifier] rather than anything larger: the only state here is "is
/// the engine open, and if not, why not", and an interface that cannot load its
/// engine has one job — to say so clearly instead of showing an empty library
/// that looks like you have no recordings.
class EngineHost extends ChangeNotifier {
  VoxScriptaEngine? _engine;
  String? _failure;

  VoxScriptaEngine? get engine => _engine;

  /// Why the engine would not open. Shown to the user verbatim: it names the
  /// path it tried, which is the one thing that makes this fixable.
  String? get failure => _failure;

  bool get isReady => _engine != null;

  void open() {
    try {
      _engine = VoxScriptaEngine.open(libraryPath: _locateLibrary());
      _failure = null;
    } on VoxScriptaException catch (error) {
      _engine = null;
      _failure = error.message;
    }
    notifyListeners();
  }

  /// Finds libVoxScriptaFFI.
  ///
  /// A packaged application will have it beside the executable, which is what
  /// the engine's own default resolves. The two cases before that exist for
  /// development, where the library lives in the SwiftPM build tree and
  /// bundling it on every rebuild would be a waste of a build step.
  String? _locateLibrary() {
    final override = Platform.environment['VOXSCRIPTA_LIBRARY'];
    if (override != null && File(override).existsSync()) return override;

    if (PlatformLibraryNames.inDevelopmentTree() case final path?) return path;
    return null; // let the engine resolve the platform's own default
  }
}

/// Where a development build keeps the library.
class PlatformLibraryNames {
  const PlatformLibraryNames._();

  static String? inDevelopmentTree() {
    final name = Platform.isMacOS
        ? 'libVoxScriptaFFI.dylib'
        : Platform.isWindows
            ? 'VoxScriptaFFI.dll'
            : 'libVoxScriptaFFI.so';

    // Walks up looking for the SwiftPM build tree, rather than counting `../`.
    //
    // Counting was the first attempt and it was wrong: a bundled debug build
    // sits eight directories below flutter/app, not six, and the app launched
    // showing "the engine could not be loaded" while the identical code worked
    // under `flutter run`. The depth also differs per platform and per build
    // mode, so any fixed number is a number waiting to be wrong. Walking is
    // bounded and does not care.
    final starts = <Directory>[
      Directory.current,
      File(Platform.resolvedExecutable).parent,
    ];
    for (final start in starts) {
      var directory = start;
      for (var depth = 0; depth < 12; depth += 1) {
        for (final suffix in [
          '.build/out/Products/Debug/$name',
          '.build/debug/$name',
        ]) {
          final file = File('${directory.path}/$suffix');
          if (file.existsSync()) return file.absolute.path;
        }
        final parent = directory.parent;
        if (parent.path == directory.path) break;
        directory = parent;
      }
    }
    return null;
  }
}
