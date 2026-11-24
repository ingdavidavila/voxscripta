import 'dart:io';

import 'package:flutter/services.dart';

/// Whether the app may use the microphone.
enum MicrophoneAccess {
  granted,

  /// Not allowed right now. The person can be asked again.
  denied,

  /// Not allowed, and Android will no longer show the prompt: the only way
  /// forward is the system Settings. Said apart from [denied] because the right
  /// message differs and "try again" would do nothing.
  blocked,
}

/// Android's microphone permission, asked before recording starts.
///
/// Without it the system refuses the capture and the engine has nothing to
/// report, so a recorder that does not check first shows a live timer over
/// silence. The check lives here, in the interface, as it does in the SwiftUI
/// app, because the platform's prompt belongs to the interface.
///
/// Its own channel, separate from the paths one: that one carries paths only.
abstract interface class MicrophonePermission {
  /// Checks, and asks if the system will still show its prompt.
  Future<MicrophoneAccess> ensure();

  /// The gate for this platform, or null where none is needed. Only Android
  /// asks the application; the desktop systems prompt at first capture or have
  /// no prompt, and a gate there would be a guess.
  static MicrophonePermission? forPlatform() =>
      Platform.isAndroid ? const ChannelMicrophonePermission() : null;
}

class ChannelMicrophonePermission implements MicrophonePermission {
  const ChannelMicrophonePermission([
    this._channel = const MethodChannel(channelName),
  ]);

  static const channelName = 'dev.voxscripta.voxscripta/microphone';

  final MethodChannel _channel;

  @override
  Future<MicrophoneAccess> ensure() async {
    try {
      final status = await _channel.invokeMethod<String>('ensure');
      return switch (status) {
        'granted' => MicrophoneAccess.granted,
        'blocked' => MicrophoneAccess.blocked,
        'denied' => MicrophoneAccess.denied,
        // Anything else, including no answer, is not permission. Recording on
        // a guess is the failure this exists to prevent.
        _ => MicrophoneAccess.denied,
      };
    } on PlatformException {
      return MicrophoneAccess.denied;
    } on MissingPluginException {
      return MicrophoneAccess.denied;
    }
  }
}
