import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Getting the speech model somewhere the engine can read it, before a job.
///
/// On Android the model ships with the install and is only reachable through the
/// platform's asset reader, so the host copies it out once on first launch (see
/// `ModelStore.kt`). That takes a while for a model of several hundred megabytes,
/// so a job waits for it and the screen says what it is waiting for. Everywhere
/// else the model is an ordinary file beside the application and there is
/// nothing to prepare, which is what a null [forPlatform] means.
///
/// Nothing in this path touches the network: the file arrives with the install.
abstract interface class ModelPreparation {
  /// Resolves when the model is ready, or says why it could not be.
  ///
  /// Returns null when it is fine to start the job. That includes the case where
  /// the install carries no model at all: the engine then fails with its own
  /// message naming the path it looked in, which says more than anything this
  /// could add. A non-null result is a problem the engine would only discover
  /// later and less clearly, such as a full disk.
  ///
  /// [onProgress] receives the fraction copied, or null while it is not known.
  Future<String?> prepare({void Function(double? fraction)? onProgress});

  static ModelPreparation? forPlatform() =>
      Platform.isAndroid ? const ChannelModelPreparation() : null;
}

class ChannelModelPreparation implements ModelPreparation {
  const ChannelModelPreparation({this.pollInterval = const Duration(milliseconds: 300)});

  static const String channelName = 'dev.voxscripta.voxscripta/model';
  static const MethodChannel _channel = MethodChannel(channelName);

  final Duration pollInterval;

  @override
  Future<String?> prepare({void Function(double? fraction)? onProgress}) async {
    final timer = Timer.periodic(pollInterval, (_) async {
      if (onProgress == null) return;
      try {
        onProgress(_fraction(await _status('status')));
      } catch (_) {
        // Progress is a courtesy. The wait below is what decides the outcome.
      }
    });
    try {
      final status = await _status('prepare');
      return _failure(status);
    } on PlatformException catch (error) {
      return 'The speech model could not be prepared: ${error.message ?? error.code}';
    } on MissingPluginException {
      // No host to ask: nothing to prepare, and the engine will say what it
      // finds.
      return null;
    } finally {
      timer.cancel();
    }
  }

  Future<Map<Object?, Object?>> _status(String method) async {
    final reply = await _channel.invokeMethod<Map<Object?, Object?>>(method);
    return reply ?? const {};
  }

  static double? _fraction(Map<Object?, Object?> status) {
    if (status['state'] != 'copying') return null;
    final copied = status['copied'];
    final total = status['total'];
    if (copied is! num || total is! num || total <= 0) return null;
    return (copied / total).clamp(0.0, 1.0).toDouble();
  }

  static String? _failure(Map<Object?, Object?> status) {
    if (status['state'] != 'failed') return null;
    final error = status['error'];
    return error is String && error.isNotEmpty
        ? error
        : 'The speech model could not be prepared.';
  }
}
