import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:voxscripta_engine/voxscripta_engine.dart';

/// Reads the engine's entitlement and keeps it fresh.
///
/// Fresh matters at exactly one moment: when the third day ends while the app
/// is open. Without a tick the user would keep seeing "1 day left" until they
/// relaunched, and then be refused by the engine anyway — the interface and
/// the engine disagreeing about the same clock, which is the thing the shared
/// rule exists to prevent.
class EntitlementModel extends ChangeNotifier {
  EntitlementModel(this._engine, {Duration? tick})
      : _tick = tick ?? const Duration(minutes: 5);

  final VoxScriptaEngine _engine;
  final Duration _tick;
  Timer? _timer;

  Entitlement? _entitlement;
  String? _error;

  Entitlement? get entitlement => _entitlement;
  String? get error => _error;

  /// Whether new transcriptions and recordings may start.
  ///
  /// Optimistic until the first read lands: the engine refuses on its own, so
  /// a moment of a hopeful button is better than a wall that flashes up on
  /// every launch before the answer arrives.
  bool get allowsNewWork => _entitlement?.allowsNewWork ?? true;

  bool get shouldOfferSubscription =>
      _entitlement?.shouldOfferSubscription ?? false;

  void start() {
    refresh();
    _timer?.cancel();
    _timer = Timer.periodic(_tick, (_) => refresh());
  }

  void refresh() {
    try {
      _entitlement = _engine.entitlement();
      _error = null;
    } on VoxScriptaException catch (failure) {
      _error = failure.message;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
