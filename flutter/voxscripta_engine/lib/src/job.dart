import 'dart:async';

import 'bindings.dart';
import 'model.dart';

/// A running pipeline, turned from a thing you poll into a thing you listen to.
///
/// The ABI is a poll, deliberately: a C callback invoked from a Swift executor
/// thread would reach Dart on a thread Dart does not own. That is right for the
/// boundary and wrong for a user interface, so the polling stops here. Above
/// this class there is a [Stream] and nothing to remember to call.
///
/// Two details make the stream usable rather than merely correct. It suppresses
/// ticks that say nothing new, because ten identical rebuilds a second is a
/// waste of a frame budget. And it closes itself when the job reaches a
/// terminal state, so `await for` ends on its own instead of hanging on a
/// finished job.
class Job {
  Job._(this._bindings, this.handle, this._pollInterval) {
    _controller = StreamController<JobProgress>.broadcast();
    // Polling starts now, not when something subscribes. The job is already
    // running inside the engine, and [done] has to complete whether or not any
    // screen happens to be watching — the first version started the timer in
    // `onListen`, which meant awaiting `done` without also listening to
    // `progress` hung forever.
    _startPolling();
  }

  final VoxScriptaBindings _bindings;
  final Duration _pollInterval;

  /// The engine's handle. Exposed for diagnostics, not for calling.
  final int handle;

  late final StreamController<JobProgress> _controller;
  final Completer<JobProgress> _finished = Completer<JobProgress>();
  Timer? _timer;
  bool _disposed = false;

  JobProgress _latest = const JobProgress(
    state: JobState.starting,
    fraction: 0,
    detail: '',
  );

  /// Progress as it changes. A broadcast stream, so several widgets may watch
  /// one job; it closes when the job finishes.
  ///
  /// Broadcast streams do not replay, so a subscriber that arrives late sees
  /// only later changes. [latest] is the synchronous truth — in Flutter, pair
  /// them: `StreamBuilder(initialData: job.latest, stream: job.progress)`.
  Stream<JobProgress> get progress => _controller.stream;

  /// The most recent poll, without waiting for the next one.
  JobProgress get latest => _latest;

  /// Completes when the job reaches a terminal state, with that state.
  ///
  /// Does not throw on failure. A failed job is an outcome the interface has to
  /// display, not an exception to catch — `JobProgress.failure` carries the
  /// engine's own words.
  Future<JobProgress> get done => _finished.future;

  void _startPolling() {
    if (_disposed || _timer != null) return;
    _poll();
    _timer = Timer.periodic(_pollInterval, (_) => _poll());
  }

  void _poll() {
    if (_disposed) return;
    final state = JobState.fromCode(_bindings.jobState(handle));
    final next = JobProgress(
      state: state,
      fraction: _bindings.jobFraction(handle),
      detail: _bindings.takeString(_bindings.jobDetailCopy(handle)) ?? '',
      failure: _bindings.takeString(_bindings.jobErrorCopy(handle)),
    );

    final changed = !next.sameAs(_latest);
    _latest = next;
    if (changed && !_controller.isClosed) _controller.add(next);

    if (state.isTerminal) {
      _timer?.cancel();
      _timer = null;
      if (!_finished.isCompleted) _finished.complete(next);
      if (!_controller.isClosed) _controller.close();
    }
  }

  /// Asks the job to stop at the next stage boundary.
  ///
  /// Not a rollback. The engine persists after every stage precisely so that a
  /// stopped job is a resumable one, and what is already on disk stays there.
  void cancel() {
    if (_disposed) return;
    _bindings.jobCancel(handle);
  }

  /// Cancels the job and tells the engine to forget the handle.
  ///
  /// After this the state reads as [JobState.unknownHandle], which is the
  /// engine being honest rather than an error. Calling it twice is harmless.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _bindings.jobRelease(handle);
    if (!_finished.isCompleted) {
      _finished.complete(const JobProgress(
        state: JobState.unknownHandle,
        fraction: 0,
        detail: '',
      ));
    }
    if (!_controller.isClosed) _controller.close();
  }
}

/// Lets the engine build a [Job] without making the constructor public.
Job makeJob(VoxScriptaBindings bindings, int handle, Duration pollInterval) =>
    Job._(bindings, handle, pollInterval);
