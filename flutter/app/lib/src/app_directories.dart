import 'dart:io';

import 'package:flutter/services.dart';

/// Where this app may write, as the Android host reports it.
///
/// The engine decides the layout under whatever it is given (Projects/,
/// Recordings/, entitlement.json) and refuses a path it cannot write, so the
/// only job here is to ask the host for the app's own directory and hand it
/// over. Nothing is created and nothing is guessed: on Android there is no home
/// directory to fall back on, and a fallback that looked plausible would put the
/// library somewhere read-only, which is exactly the failure this exists to end.
///
/// One method on one channel, and paths only. Permissions, pickers and the
/// foreground service are deliberately not here: a channel that carries
/// everything becomes the place everything accumulates.
class AppDirectories {
  const AppDirectories({required this.files, required this.cache});

  /// The app's private files directory. This is what the engine is given as its
  /// data directory.
  final String files;

  /// The app's private cache directory. Not used yet; returned now because a
  /// second path is expected soon and the reply is a map precisely so that
  /// adding one changes no signature.
  final String cache;

  /// The channel name matches the Android application id, so it cannot collide
  /// with a plugin's.
  static const channelName = 'dev.voxscripta.voxscripta/paths';

  /// Whether this platform has to be asked. Android is the only one: the others
  /// resolve a per-user data directory themselves, in the engine.
  static bool get isRequired => Platform.isAndroid;

  /// Asks the host. Returns null on platforms that do not need to be asked.
  ///
  /// Throws [AppDirectoriesException] if Android is asked and cannot answer, so
  /// the caller can say so instead of opening an engine that would fail later in
  /// a less legible place.
  static Future<AppDirectories?> load() async {
    if (!isRequired) return null;
    return fromChannel(const MethodChannel(channelName));
  }

  /// The part that does not depend on the platform, separate so it can be
  /// tested with a channel that is not the real one.
  static Future<AppDirectories> fromChannel(MethodChannel channel) async {
    final Map<String, String>? reply;
    try {
      reply = await channel.invokeMapMethod<String, String>('getPaths');
    } on PlatformException catch (error) {
      throw AppDirectoriesException(
          'the host could not report its directories: ${error.message}');
    } on MissingPluginException {
      throw const AppDirectoriesException(
          'the host does not answer on $channelName, so the app cannot know '
          'where it may write');
    }

    final files = reply?['files'];
    final cache = reply?['cache'];
    if (files == null || files.isEmpty || cache == null || cache.isEmpty) {
      throw AppDirectoriesException(
          'the host answered without both directories: $reply');
    }
    return AppDirectories(files: files, cache: cache);
  }
}

class AppDirectoriesException implements Exception {
  const AppDirectoriesException(this.message);

  final String message;

  @override
  String toString() => message;
}
