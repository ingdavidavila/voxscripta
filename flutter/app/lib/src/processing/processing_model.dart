import 'package:flutter/foundation.dart';
import 'package:voxscripta_engine/voxscripta_engine.dart';

/// What the processing screen needs from the engine.
abstract interface class ProcessingSource {
  Job start({required String projectPath, String? audioPath, JobOptions? options});
  ProjectSummary summary(String projectPath);
  List<(double, double)>? waveform(String projectPath, {int buckets});
}

class EngineProcessingSource implements ProcessingSource {
  const EngineProcessingSource(this._engine);

  final VoxScriptaEngine _engine;

  @override
  Job start({
    required String projectPath,
    String? audioPath,
    JobOptions? options,
  }) =>
      _engine.startJob(
        projectPath: projectPath,
        audioPath: audioPath,
        options: options,
      );

  @override
  ProjectSummary summary(String projectPath) => _engine.summary(projectPath);

  @override
  List<(double, double)>? waveform(String projectPath, {int buckets = 0}) =>
      _engine.waveform(projectPath, buckets: buckets);
}

/// The pipeline's phases, in the order a job runs them.
///
/// Not every `JobState` is a phase — `imported`, `complete`, `failed` and
/// `cancelled` are outcomes rather than work — so the list is written out
/// instead of derived from the enum.
const processingPhases = <(JobState, String)>[
  (JobState.analyzing, 'Analyze audio'),
  (JobState.silenceProcessing, 'Detect silence'),
  (JobState.chunking, 'Plan segments'),
  (JobState.transcribing, 'Transcribe'),
  (JobState.merging, 'Assemble transcript'),
  (JobState.cleaning, 'Clean'),
  (JobState.polishing, 'Polish'),
];

/// Watches one job.
///
/// §18 asks that this never look frozen, which is why the waveform and the
/// speech summary are polled alongside the progress: they appear as soon as
/// the stages that produce them finish, which is well before transcription
/// ends — so there is something real on screen during the longest phase.
class ProcessingModel extends ChangeNotifier {
  ProcessingModel({
    required ProcessingSource source,
    required this.projectPath,
    required this.displayName,
    this.audioPath,
    this.options,
  }) : _source = source;

  factory ProcessingModel.of(
    VoxScriptaEngine engine, {
    required String projectPath,
    required String displayName,
    String? audioPath,
    JobOptions? options,
  }) =>
      ProcessingModel(
        source: EngineProcessingSource(engine),
        projectPath: projectPath,
        displayName: displayName,
        audioPath: audioPath,
        options: options,
      );

  final ProcessingSource _source;
  final String projectPath;
  /// Needed only to create a project. Null resumes one that exists.
  final String? audioPath;
  final String displayName;
  final JobOptions? options;

  Job? _job;
  JobProgress _progress = const JobProgress(
    state: JobState.starting,
    fraction: 0,
    detail: '',
  );
  AudioFacts? _audio;
  List<(double, double)>? _waveform;
  String? _startFailure;

  JobProgress get progress => _progress;
  AudioFacts? get audio => _audio;
  List<(double, double)>? get waveform => _waveform;

  /// Why the job would not start at all, as opposed to failing once running.
  String? get startFailure => _startFailure;

  bool get isFinished => _progress.state.isTerminal;

  /// How many buckets the waveform is fetched at. Set from the width of the
  /// view before loading, so the engine downsamples once instead of Dart
  /// throwing away points it was given.
  int waveformBuckets = 600;

  void start() {
    if (_job != null || _startFailure != null) return;
    try {
      final job = _source.start(
        projectPath: projectPath,
        audioPath: audioPath,
        options: options,
      );
      _job = job;
      job.progress.listen(_onProgress, onDone: _refreshFacts);
      _progress = job.latest;
    } on VoxScriptaException catch (failure) {
      _startFailure = failure.message;
    }
    _refreshFacts();
    notifyListeners();
  }

  void _onProgress(JobProgress report) {
    final previous = _progress.state;
    _progress = report;
    // The facts are re-read when the phase changes rather than on every tick.
    // Nothing new appears mid-phase, and re-reading a manifest ten times a
    // second to learn the same thing is a waste of a frame budget.
    if (report.state != previous) _refreshFacts();
    notifyListeners();
  }

  void _refreshFacts() {
    try {
      final summary = _source.summary(projectPath);
      _audio = summary.audio;
      if (_waveform == null && summary.audio.hasWaveform) {
        _waveform = _source.waveform(projectPath, buckets: waveformBuckets);
      }
    } on VoxScriptaException {
      // A project that cannot be summarised yet is normal early on — the
      // manifest may not be written. The progress line is the source of truth
      // for whether anything is wrong.
    }
    notifyListeners();
  }

  void cancel() => _job?.cancel();

  @override
  void dispose() {
    _job?.dispose();
    super.dispose();
  }
}
