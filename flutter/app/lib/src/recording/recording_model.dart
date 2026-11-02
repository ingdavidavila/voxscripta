import 'package:flutter/foundation.dart';
import 'package:voxscripta_engine/voxscripta_engine.dart';

/// What the recording screen needs from the engine.
abstract interface class RecordingSource {
  Recording start({String? destinationPath});
  String get directory;
}

class EngineRecordingSource implements RecordingSource {
  const EngineRecordingSource(this._engine);

  final VoxScriptaEngine _engine;

  @override
  Recording start({String? destinationPath}) =>
      _engine.startRecording(destinationPath: destinationPath);

  @override
  String get directory => _engine.recordingDirectory;
}

/// The recording screen's state.
///
/// Keeps a short history of levels so the meter can scroll, which is the one
/// piece of state here that is genuinely the interface's: the engine reports
/// the level now, and how many bars of it to remember is a drawing decision.
class RecordingModel extends ChangeNotifier {
  RecordingModel({required RecordingSource source}) : _source = source;

  factory RecordingModel.of(VoxScriptaEngine engine) =>
      RecordingModel(source: EngineRecordingSource(engine));

  final RecordingSource _source;

  /// How many level samples the meter remembers. At the engine's 50 ms poll
  /// that is about three seconds of history.
  static const int meterHistory = 60;

  Recording? _recording;
  RecordingProgress _progress = const RecordingProgress(
    state: RecordingState.idle,
    elapsed: Duration.zero,
    level: 0,
  );
  final List<double> _levels = [];
  String? _startFailure;
  RecordingResult? _result;

  RecordingProgress get progress => _progress;
  List<double> get levels => List.unmodifiable(_levels);
  String? get startFailure => _startFailure;

  /// Set once the recording has been finished, so the shell can hand the file
  /// on to the import path.
  RecordingResult? get result => _result;

  bool get isActive => _recording != null;
  String get directory => _source.directory;

  void start() {
    if (_recording != null) return;
    _startFailure = null;
    try {
      final recording = _source.start();
      _recording = recording;
      _progress = recording.latest;
      recording.progress.listen(_onProgress);
    } on VoxScriptaException catch (failure) {
      // The engine's own words — "no microphone is available", "the microphone
      // did not start" — which are the difference between a fixable problem
      // and a mystery.
      _startFailure = failure.message;
    }
    notifyListeners();
  }

  void _onProgress(RecordingProgress report) {
    _progress = report;
    _levels.add(report.level);
    if (_levels.length > meterHistory) _levels.removeAt(0);
    notifyListeners();
  }

  void pause() {
    _recording?.pause();
    notifyListeners();
  }

  void resume() {
    _recording?.resume();
    notifyListeners();
  }

  /// Stops and keeps the file.
  RecordingResult? finish() {
    final recording = _recording;
    if (recording == null) return null;
    try {
      _result = recording.finish();
    } on VoxScriptaException catch (failure) {
      _startFailure = failure.message;
    }
    _recording = null;
    notifyListeners();
    return _result;
  }

  /// Stops and deletes the file. Only ever from an explicit choice — §5
  /// protects original files, and a recording just thrown away is not one yet.
  void discard() {
    _recording?.discard();
    _recording = null;
    _levels.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    // A screen going away must not quietly destroy audio, so an unfinished
    // recording is finished rather than discarded. The file is on disk either
    // way — the writer has been emitting fragments all along — and finishing
    // is what makes it tidy.
    _recording?.finish();
    _recording = null;
    super.dispose();
  }
}

/// `h:mm:ss` once there is an hour, `m:ss` before that.
///
/// Matches the SwiftUI recorder exactly. Formatted rather than date-styled
/// because this is an elapsed duration, and the hour place should appear when
/// it is reached instead of sitting at zero for the first hour of every
/// recording.
String formatRecordingClock(Duration elapsed) {
  final total = elapsed.inSeconds;
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  final ss = seconds.toString().padLeft(2, '0');
  if (hours > 0) return '$hours:${minutes.toString().padLeft(2, '0')}:$ss';
  return '$minutes:$ss';
}
