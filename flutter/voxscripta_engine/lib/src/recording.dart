import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bindings.dart';
import 'model.dart';

/// Where a recording has got to.
enum RecordingState {
  idle,
  recording,
  paused,

  /// The engine does not know this handle — finished, discarded, or never
  /// issued.
  unknownHandle;

  static RecordingState fromCode(int code) => switch (code) {
        0 => RecordingState.idle,
        1 => RecordingState.recording,
        2 => RecordingState.paused,
        _ => RecordingState.unknownHandle,
      };
}

/// One poll of a recording in progress.
class RecordingProgress {
  const RecordingProgress({
    required this.state,
    required this.elapsed,
    required this.level,
    this.failure,
  });

  final RecordingState state;
  final Duration elapsed;

  /// The meter, in `0...1`, already mapped by the engine's measured curve.
  final double level;

  /// Set when capture or writing failed part-way through. The file written so
  /// far is still good, which is why this is a report rather than a state.
  final String? failure;

  bool sameAs(RecordingProgress other) =>
      state == other.state &&
      elapsed.inMilliseconds == other.elapsed.inMilliseconds &&
      (level - other.level).abs() < 0.004 &&
      failure == other.failure;
}

/// What a finished recording produced.
class RecordingResult {
  const RecordingResult({required this.path, required this.duration});

  final String path;
  final Duration duration;
}

/// A recording in progress.
///
/// Polled rather than pushed, like [Job] and for the same reason: a meter
/// calling back into Dart from a capture thread is the crash that shape was
/// designed to avoid.
///
/// Faster than a job, though — 20 Hz rather than 10 — because a meter that
/// updates ten times a second reads as laggy where a progress bar does not.
class Recording {
  Recording._(this._bindings, this.handle, this._pollInterval) {
    _controller = StreamController<RecordingProgress>.broadcast();
    _poll();
    _timer = Timer.periodic(_pollInterval, (_) => _poll());
  }

  final VoxScriptaBindings _bindings;
  final Duration _pollInterval;

  /// The engine's handle. For diagnostics, not for calling.
  final int handle;

  late final StreamController<RecordingProgress> _controller;
  Timer? _timer;
  bool _closed = false;

  RecordingProgress _latest = const RecordingProgress(
    state: RecordingState.idle,
    elapsed: Duration.zero,
    level: 0,
  );

  /// Changes only. Pair with [latest] in a `StreamBuilder`, since a broadcast
  /// stream does not replay.
  Stream<RecordingProgress> get progress => _controller.stream;

  RecordingProgress get latest => _latest;

  void _poll() {
    if (_closed) return;
    final next = RecordingProgress(
      state: RecordingState.fromCode(_bindings.recordingState(handle)),
      elapsed: Duration(
          microseconds: (_bindings.recordingElapsed(handle) * 1e6).round()),
      level: _bindings.recordingLevel(handle),
      failure: _bindings.takeString(_bindings.recordingFailureCopy(handle)),
    );
    final changed = !next.sameAs(_latest);
    _latest = next;
    if (changed && !_controller.isClosed) _controller.add(next);
  }

  void pause() => _bindings.recordingPause(handle);
  void resume() => _bindings.recordingResume(handle);

  /// Stops and finalizes. The file was readable before this; finishing tidies
  /// it. The handle is spent afterwards.
  RecordingResult? finish() {
    if (_closed) return null;
    final out = calloc<Pointer<Utf8>>();
    try {
      final status = _bindings.recordingFinish(handle, out);
      if (status != 0) {
        throw VoxScriptaException(
          _bindings.lastError() ?? 'the recording could not be finished',
          code: status,
        );
      }
      final text = _bindings.takeString(out.value);
      if (text == null) return null;
      final json = jsonDecode(text) as Map<String, Object?>;
      return RecordingResult(
        path: json['path'] as String? ?? '',
        duration: Duration(
            microseconds: (((json['seconds'] as num?) ?? 0) * 1e6).round()),
      );
    } finally {
      calloc.free(out);
      _close();
    }
  }

  /// Stops and deletes what was written. The handle is spent afterwards.
  void discard() {
    if (_closed) return;
    _bindings.recordingDiscard(handle);
    _close();
  }

  void _close() {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    // The handle is spent, so say so. Cancelling the timer alone left `latest`
    // holding the last poll — a finished recording still reported `recording`,
    // which a screen reading `latest.state` would have believed. Found by
    // `tool/record_check.dart`, which prints the state after finishing.
    _latest = RecordingProgress(
      state: RecordingState.unknownHandle,
      elapsed: _latest.elapsed,
      level: 0,
      failure: _latest.failure,
    );
    if (!_controller.isClosed) {
      _controller.add(_latest);
      _controller.close();
    }
  }
}

/// Lets the engine build a [Recording] without exposing the constructor.
Recording makeRecording(
        VoxScriptaBindings bindings, int handle, Duration pollInterval) =>
    Recording._(bindings, handle, pollInterval);
