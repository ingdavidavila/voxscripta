/// Where a job has got to.
///
/// Mirrors the `VS_STATE_*` codes in `ffi/voxscripta.h`. The mapping is an
/// explicit switch rather than an index into `values`, for the same reason it
/// is an explicit switch on the Swift side: a case inserted in the engine must
/// not silently renumber what a shipped build already understands.
enum JobState {
  /// Accepted, but no stage has reported yet.
  starting,
  imported,
  analyzing,
  silenceProcessing,
  chunking,
  transcribing,
  merging,
  cleaning,
  polishing,
  complete,
  failed,
  cancelled,

  /// The engine does not know this handle — it was released, or never issued.
  /// Reachable after [Job.dispose], and after a hot restart leaves Dart holding
  /// a handle the library has forgotten.
  unknownHandle;

  static JobState fromCode(int code) => switch (code) {
        0 => JobState.imported,
        1 => JobState.analyzing,
        2 => JobState.silenceProcessing,
        3 => JobState.chunking,
        4 => JobState.transcribing,
        5 => JobState.merging,
        6 => JobState.cleaning,
        7 => JobState.polishing,
        8 => JobState.complete,
        9 => JobState.failed,
        10 => JobState.cancelled,
        100 => JobState.starting,
        _ => JobState.unknownHandle,
      };

  /// Whether nothing further will happen. The poll stops here.
  bool get isTerminal => switch (this) {
        JobState.complete ||
        JobState.failed ||
        JobState.cancelled ||
        JobState.unknownHandle =>
          true,
        _ => false,
      };
}

/// One poll's worth of answer.
class JobProgress {
  const JobProgress({
    required this.state,
    required this.fraction,
    required this.detail,
    this.failure,
  });

  final JobState state;

  /// Completion in `0...1`.
  final double fraction;

  /// The line to show — "Transcribing", "Language: es-ES (…)".
  final String detail;

  /// Why the job failed, when it did. Null otherwise.
  final String? failure;

  /// Compared so the stream can suppress repeats. Polling runs at 10 Hz and
  /// most ticks say nothing new; forwarding them all would rebuild a Flutter
  /// tree ten times a second to redraw the same pixels.
  bool sameAs(JobProgress other) =>
      state == other.state &&
      fraction == other.fraction &&
      detail == other.detail &&
      failure == other.failure;

  @override
  String toString() => 'JobProgress(${state.name}, '
      '${(fraction * 100).toStringAsFixed(0)}%, "$detail"'
      '${failure == null ? '' : ', failure: $failure'})';
}

/// Which of the three transcripts to read.
///
/// The names are the wire format — they are the raw values of the engine's own
/// `TranscriptVariant`, and the ABI takes them as strings so that adding a
/// fourth never shifts the meaning of the first three.
enum TranscriptVariant {
  /// Exactly what was said, disfluencies included.
  verbatim,

  /// Deterministic readability rules. No model involved.
  clean,

  /// The validated model pass.
  polished;

  String get wireName => name;
}

/// An output format, named by its file extension, as the ABI expects.
enum ExportFormat {
  plainText('txt'),
  markdown('md'),
  word('docx'),
  subRip('srt'),
  webVTT('vtt');

  const ExportFormat(this.wireName);
  final String wireName;
}

/// A refusal from the engine, carrying what it said rather than a code.
class VoxScriptaException implements Exception {
  const VoxScriptaException(this.message, {this.code});

  final String message;
  final int? code;

  @override
  String toString() =>
      'VoxScriptaException: $message${code == null ? '' : ' (code $code)'}';
}
