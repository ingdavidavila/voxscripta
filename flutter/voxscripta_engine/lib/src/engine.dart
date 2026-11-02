import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart';
import 'job.dart';
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
  static const int supportedAbiVersion = 1;

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
  Job startJob({required String audioPath, required String projectPath}) {
    final audio = audioPath.toNativeUtf8();
    final project = projectPath.toNativeUtf8();
    try {
      final handle = _bindings.jobStart(audio, project);
      if (handle <= 0) {
        throw VoxScriptaException(
          _bindings.lastError() ?? 'the engine refused to start the job',
        );
      }
      return makeJob(_bindings, handle, pollInterval);
    } finally {
      calloc.free(audio);
      calloc.free(project);
    }
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
  }) {
    final path = libraryPath;
    return Isolate.run(() => _exportSync(
          libraryPath: path,
          projectPath: projectPath,
          variant: variant,
          format: format,
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
  }) =>
      _runExport(
        bindings: _bindings,
        projectPath: projectPath,
        variant: variant,
        format: format,
      );

  static Uint8List _exportSync({
    required String libraryPath,
    required String projectPath,
    required TranscriptVariant variant,
    required ExportFormat format,
  }) =>
      _runExport(
        bindings: VoxScriptaBindings(DynamicLibrary.open(libraryPath)),
        projectPath: projectPath,
        variant: variant,
        format: format,
      );

  static Uint8List _runExport({
    required VoxScriptaBindings bindings,
    required String projectPath,
    required TranscriptVariant variant,
    required ExportFormat format,
  }) {
    final project = projectPath.toNativeUtf8();
    final variantName = variant.wireName.toNativeUtf8();
    final formatName = format.wireName.toNativeUtf8();
    final outBytes = calloc<Pointer<Uint8>>();
    final outLength = calloc<Int64>();
    try {
      final status =
          bindings.export(project, variantName, formatName, outBytes, outLength);
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
      calloc.free(outBytes);
      calloc.free(outLength);
    }
  }
}
