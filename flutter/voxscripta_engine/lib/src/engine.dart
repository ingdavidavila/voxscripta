import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart';
import 'job.dart';
import 'recording.dart';
import 'model.dart';

/// The engine, as Dart sees it.
///
/// One instance per isolate. Opening the library twice is cheap — the platform
/// loaders reference-count — so an isolate that needs it opens its own rather
/// than trying to send a [DynamicLibrary] it cannot send.
class VoxScriptaEngine {
  VoxScriptaEngine._(this._bindings, this.libraryPath, this.pollInterval);

  /// The ABI this package was written against. A library announcing anything
  /// else is refused at open, rather than crashing later on a signature that
  /// moved — which is the whole reason the version exists.
  static const int supportedAbiVersion = 8;

  /// How often a running job is polled.
  ///
  /// 100 ms, matching the SwiftUI app's own progress tick. Chosen there by
  /// measurement rather than taste, and there is no reason for the two
  /// interfaces to feel different.
  static const Duration defaultPollInterval = Duration(milliseconds: 100);

  final VoxScriptaBindings _bindings;
  final String libraryPath;
  final Duration pollInterval;

  /// Opens the engine.
  ///
  /// [libraryPath] defaults to the platform's own filename, resolved by the
  /// system loader — which is what a bundled application wants, since the
  /// library sits beside the executable. Pass a path explicitly when driving a
  /// build tree, as the tests do.
  ///
  /// Throws [VoxScriptaException] if the library will not load or announces an
  /// ABI this package does not speak.
  factory VoxScriptaEngine.open({
    String? libraryPath,
    Duration pollInterval = defaultPollInterval,
  }) {
    final path = libraryPath ?? defaultLibraryName;
    final DynamicLibrary library;
    try {
      library = DynamicLibrary.open(path);
    } on Object catch (error) {
      throw VoxScriptaException('could not load the engine at $path: $error');
    }

    final bindings = VoxScriptaBindings(library);
    final version = bindings.abiVersion();
    if (version != supportedAbiVersion) {
      throw VoxScriptaException(
        'engine speaks ABI $version, this package speaks $supportedAbiVersion',
      );
    }
    return VoxScriptaEngine._(bindings, path, pollInterval);
  }

  /// What the library is called on each platform.
  ///
  /// SwiftPM names the Apple and Linux products with a `lib` prefix; Windows
  /// has none. Android is the same `.so` as Linux because it is the same
  /// SwiftPM product under a different triple.
  static String get defaultLibraryName {
    if (Platform.isMacOS || Platform.isIOS) return 'libVoxScriptaFFI.dylib';
    if (Platform.isWindows) return 'VoxScriptaFFI.dll';
    return 'libVoxScriptaFFI.so';
  }

  /// The ABI the loaded library announces.
  int get abiVersion => _bindings.abiVersion();

  /// Creates or opens the project at [projectPath] for the audio at
  /// [audioPath], and starts the pipeline.
  ///
  /// Returns at once; watch [Job.progress] or await [Job.done]. The original
  /// audio is referenced, never copied and never modified.
  ///
  /// Throws [VoxScriptaException] if the engine refuses to start — a bad path,
  /// typically — with the engine's own explanation.
  /// Starts the pipeline for [projectPath].
  ///
  /// [audioPath] is required only to *create* a project. Leave it null to
  /// resume one that already exists — a package references its own source, so
  /// re-running it needs no audio path.
  Job startJob({
    required String projectPath,
    String? audioPath,
    JobOptions? options,
  }) {
    final audio = (audioPath ?? '').toNativeUtf8();
    final project = projectPath.toNativeUtf8();
    final settings =
        options == null ? nullptr : jsonEncode(options.toJson()).toNativeUtf8();
    try {
      final handle = _bindings.jobStart(audio, project, settings.cast());
      if (handle <= 0) {
        throw VoxScriptaException(
          _bindings.lastError() ?? 'the engine refused to start the job',
          code: handle,
        );
      }
      return makeJob(_bindings, handle, pollInterval);
    } finally {
      calloc.free(audio);
      calloc.free(project);
      if (settings != nullptr) calloc.free(settings);
    }
  }

  // ── The library ──────────────────────────────────────────────────────────

  /// Where projects live when nobody says otherwise.
  ///
  /// Read from the engine rather than rebuilt here, so the Flutter and SwiftUI
  /// interfaces cannot end up pointing at two different libraries.
  String get defaultLibraryDirectory =>
      _bindings.takeString(_bindings.libraryDefaultDirectory()) ?? '';

  /// The projects in [directory], newest first.
  ///
  /// Defaults to [defaultLibraryDirectory]. An empty library is an empty list,
  /// not an error — a fresh install should show an empty shelf.
  List<ProjectEntry> library({String? directory}) {
    final path = (directory ?? '').toNativeUtf8();
    try {
      final text = _bindings.takeString(_bindings.libraryList(path));
      if (text == null) {
        throw VoxScriptaException(
            _bindings.lastError() ?? 'the library could not be read');
      }
      final rows = jsonDecode(text) as List<Object?>;
      return rows
          .cast<Map<String, Object?>>()
          .map(ProjectEntry.fromJson)
          .toList(growable: false);
    } finally {
      calloc.free(path);
    }
  }

  /// Deletes a project, recoverably.
  ///
  /// Returns where it went — the Trash on a Mac, a Deleted folder elsewhere —
  /// or null when the platform could not say. The original audio survives
  /// either way, which is the promise that matters.
  String? deleteProject(String projectPath) {
    final path = projectPath.toNativeUtf8();
    final out = calloc<Pointer<Utf8>>();
    try {
      final status = _bindings.projectDelete(path, out);
      if (status != 0) {
        throw VoxScriptaException(
          _bindings.lastError() ?? 'the project could not be deleted',
          code: status,
        );
      }
      final text = _bindings.takeString(out.value);
      if (text == null) return null;
      return (jsonDecode(text) as Map<String, Object?>)['movedTo'] as String?;
    } finally {
      calloc.free(path);
      calloc.free(out);
    }
  }

  /// What a project contains: which transcripts exist, how long each is, and
  /// what POLISH decided.
  ///
  /// One call rather than four, because the transcript screen needs all of it
  /// to draw a single frame. A project with nothing finished reports no
  /// variants, which is a state to show and not an error.
  ProjectSummary summary(String projectPath) {
    final path = projectPath.toNativeUtf8();
    try {
      final text = _bindings.takeString(_bindings.projectSummary(path));
      if (text == null) {
        throw VoxScriptaException(
            _bindings.lastError() ?? 'the project could not be read');
      }
      return ProjectSummary.fromJson(jsonDecode(text) as Map<String, Object?>);
    } finally {
      calloc.free(path);
    }
  }

  /// What this build on this machine can do: the transcription languages it
  /// offers, which of them the text stages understand, which have enough
  /// defence for POLISH, and which model POLISH would actually use.
  ///
  /// Every line of it is a rule, which is why it is read rather than computed.
  /// Blocks briefly — asking the recogniser which locales it supports is a
  /// call into a system service.
  Capabilities capabilities() {
    final text = _bindings.takeString(_bindings.capabilities());
    if (text == null) {
      throw VoxScriptaException(
          _bindings.lastError() ?? 'the engine would not report its capabilities');
    }
    return Capabilities.fromJson(jsonDecode(text) as Map<String, Object?>);
  }

  /// The waveform, as min/max pairs in `-1...1`.
  ///
  /// [buckets] should be the pixel width of the view that will draw it; the
  /// engine downsamples by taking each span's extremes, which is the only
  /// reduction that keeps a waveform looking like the audio. Returns null
  /// before the analysis stage has run — a state to show, not an error.
  List<(double min, double max)>? waveform(String projectPath, {int buckets = 0}) {
    final path = projectPath.toNativeUtf8();
    final outBytes = calloc<Pointer<Uint8>>();
    final outLength = calloc<Int64>();
    try {
      final status = _bindings.waveform(path, buckets, outBytes, outLength);
      if (status != 0) return null;
      final buffer = outBytes.value;
      try {
        final floats = buffer.cast<Float>().asTypedList(outLength.value ~/ 4);
        return [
          for (var index = 0; index + 1 < floats.length; index += 2)
            (floats[index], floats[index + 1]),
        ];
      } finally {
        _bindings.bytesFree(buffer);
      }
    } finally {
      calloc.free(path);
      calloc.free(outBytes);
      calloc.free(outLength);
    }
  }

  // ── Sign-up rules ────────────────────────────────────────────────────────

  /// The password rules, each marked met or not.
  ///
  /// Read from the engine rather than reimplemented here: a password that
  /// passed on a phone and failed on a desktop would be a bug, and one
  /// definition is the only way to prevent it. All rules come back every
  /// time, so a form can show the whole checklist filling in.
  List<PasswordRule> passwordRules(String password) {
    final text = password.toNativeUtf8();
    try {
      final json = _bindings.takeString(_bindings.passwordRules(text));
      if (json == null) {
        throw VoxScriptaException(
            _bindings.lastError() ?? 'the password rules could not be read');
      }
      return (jsonDecode(json) as List<Object?>)
          .cast<Map<String, Object?>>()
          .map(PasswordRule.fromJson)
          .toList(growable: false);
    } finally {
      calloc.free(text);
    }
  }

  /// Whether a string could be an email address. Permissive by design.
  bool emailLooksValid(String address) {
    final text = address.toNativeUtf8();
    try {
      return _bindings.emailLooksValid(text) == 1;
    } finally {
      calloc.free(text);
    }
  }

  // ── The paywall ──────────────────────────────────────────────────────────

  /// What this machine may do: the trial, or the subscription after it.
  ///
  /// Read from the engine for the same reason the password rules are: the
  /// trial clock has to mean the same thing in both interfaces, and a clock
  /// implemented twice would disagree about a machine that slept through the
  /// deadline. The engine also enforces it — `start` and `startRecording`
  /// refuse on their own — so this is for *showing* the state, not for
  /// deciding it.
  ///
  /// Reading it moves the trial's high-water mark forward, which is what stops
  /// a clock set backwards from returning days already spent.
  Entitlement entitlement() {
    final json = _bindings.takeString(_bindings.entitlementState());
    if (json == null) {
      throw VoxScriptaException(
          _bindings.lastError() ?? 'the entitlement could not be read');
    }
    return Entitlement.fromJson(jsonDecode(json) as Map<String, Object?>);
  }

  /// Records a subscription the platform has already verified.
  ///
  /// Verification cannot happen here. The proof is a StoreKit 2 transaction
  /// signed by Apple or a Play Billing purchase, both of which live on the
  /// platform side of the channel; this records the outcome. The wall is
  /// therefore exactly as strong as the code that calls this.
  void recordSubscription({
    required String productID,
    required BillingPeriod period,
    DateTime? expires,
    DateTime? graceUntil,
  }) {
    final payload = jsonEncode({
      'productID': productID,
      'period': period.wireName,
      if (expires != null)
        'expires': expires.millisecondsSinceEpoch / 1000.0,
      if (graceUntil != null)
        'graceUntil': graceUntil.millisecondsSinceEpoch / 1000.0,
    });
    final text = payload.toNativeUtf8();
    try {
      if (_bindings.entitlementRecordSubscription(text) != 0) {
        throw VoxScriptaException(
            _bindings.lastError() ?? 'the subscription could not be recorded');
      }
    } finally {
      calloc.free(text);
    }
  }

  /// Forgets the subscription: a refund, or a restore that found nothing.
  ///
  /// The trial clock is untouched, so this does not hand back a trial that has
  /// already been spent.
  void clearSubscription() => _bindings.entitlementClearSubscription();

  // ── Recording ────────────────────────────────────────────────────────────

  /// How often a recording is polled.
  ///
  /// 50 ms rather than the job's 100: a meter updating ten times a second
  /// reads as laggy where a progress bar does not.
  static const Duration defaultMeterInterval = Duration(milliseconds: 50);

  /// Where recordings are written. Read from the engine so both interfaces
  /// agree about where a recording lands.
  String get recordingDirectory =>
      _bindings.takeString(_bindings.recordingDirectory()) ?? '';

  /// A new, non-colliding recording path inside that directory.
  String newRecordingPath() =>
      _bindings.takeString(_bindings.recordingNewPath()) ?? '';

  /// Opens the microphone and starts writing.
  ///
  /// [destinationPath] defaults to a newly generated one. The file is readable
  /// while it is being written — the writer emits fragments, so a crash costs
  /// the last fragment rather than the recording.
  ///
  /// Throws [VoxScriptaException] when the device will not open, with the
  /// engine's own reason.
  Recording startRecording({String? destinationPath}) {
    final path = (destinationPath ?? '').toNativeUtf8();
    try {
      final handle = _bindings.recordingStart(path);
      if (handle <= 0) {
        throw VoxScriptaException(
          _bindings.lastError() ?? 'the microphone could not be opened',
          code: handle,
        );
      }
      return makeRecording(_bindings, handle, defaultMeterInterval);
    } finally {
      calloc.free(path);
    }
  }

  // ── Defaults ─────────────────────────────────────────────────────────────

  /// The engine's own job settings.
  ///
  /// A settings screen renders from this rather than from literals, so that the
  /// engine changing a default changes both interfaces at once.
  Map<String, Object?> get jobOptionDefaults =>
      _decodeDefaults(_bindings.jobOptionsDefaults(), 'job options');

  /// The engine's own export settings.
  Map<String, Object?> get exportOptionDefaults =>
      _decodeDefaults(_bindings.exportOptionsDefaults(), 'export options');

  Map<String, Object?> _decodeDefaults(Pointer<Utf8> pointer, String what) {
    final text = _bindings.takeString(pointer);
    if (text == null) {
      throw VoxScriptaException(
          _bindings.lastError() ?? 'the engine would not report its $what');
    }
    return jsonDecode(text) as Map<String, Object?>;
  }

  /// Renders a finished transcript.
  ///
  /// Unlike starting a job, this one really does work before it returns: it
  /// reads a transcript off disk and renders it, and `docx` builds a ZIP. So it
  /// runs on a helper isolate, which is why the library is re-opened inside
  /// rather than captured — a [DynamicLibrary] cannot cross an isolate, but the
  /// path can, and opening it again only bumps a reference count.
  Future<Uint8List> export({
    required String projectPath,
    required TranscriptVariant variant,
    required ExportFormat format,
    ExportOptions? options,
  }) {
    final path = libraryPath;
    final settings = options == null ? null : jsonEncode(options.toJson());
    return Isolate.run(() => _exportSync(
          libraryPath: path,
          projectPath: projectPath,
          variant: variant,
          format: format,
          settingsJson: settings,
        ));
  }

  /// The same render, on the calling isolate.
  ///
  /// Here for tests and for a caller that is already off the UI isolate.
  /// Prefer [export].
  Uint8List exportSync({
    required String projectPath,
    required TranscriptVariant variant,
    required ExportFormat format,
    ExportOptions? options,
  }) =>
      _runExport(
        bindings: _bindings,
        projectPath: projectPath,
        variant: variant,
        format: format,
        settingsJson: options == null ? null : jsonEncode(options.toJson()),
      );

  static Uint8List _exportSync({
    required String libraryPath,
    required String projectPath,
    required TranscriptVariant variant,
    required ExportFormat format,
    String? settingsJson,
  }) =>
      _runExport(
        bindings: VoxScriptaBindings(DynamicLibrary.open(libraryPath)),
        projectPath: projectPath,
        variant: variant,
        format: format,
        settingsJson: settingsJson,
      );

  static Uint8List _runExport({
    required VoxScriptaBindings bindings,
    required String projectPath,
    required TranscriptVariant variant,
    required ExportFormat format,
    String? settingsJson,
  }) {
    final project = projectPath.toNativeUtf8();
    final variantName = variant.wireName.toNativeUtf8();
    final formatName = format.wireName.toNativeUtf8();
    final settings = settingsJson == null ? nullptr : settingsJson.toNativeUtf8();
    final outBytes = calloc<Pointer<Uint8>>();
    final outLength = calloc<Int64>();
    try {
      final status = bindings.export(
          project, variantName, formatName, settings.cast(), outBytes, outLength);
      if (status != 0) {
        throw VoxScriptaException(
          bindings.lastError() ?? 'the export failed',
          code: status,
        );
      }
      final buffer = outBytes.value;
      final length = outLength.value;
      try {
        // Copied, not viewed. The view would reference memory this function is
        // about to hand back to the engine.
        return Uint8List.fromList(buffer.asTypedList(length));
      } finally {
        bindings.bytesFree(buffer);
      }
    } finally {
      calloc.free(project);
      calloc.free(variantName);
      calloc.free(formatName);
      if (settings != nullptr) calloc.free(settings);
      calloc.free(outBytes);
      calloc.free(outLength);
    }
  }
}
