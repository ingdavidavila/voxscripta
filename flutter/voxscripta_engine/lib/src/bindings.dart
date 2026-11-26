import 'dart:convert';
import 'dart:ffi';
import 'package:ffi/ffi.dart';

import 'model.dart' show VoxScriptaException;

/// The symbols of `ffi/voxscripta.h`, and nothing else.
///
/// The count used to be written here and was wrong twice; Tools/check-abi.sh
/// holds it, where it is checked rather than remembered.
///
/// Hand-written rather than generated. ffigen would need libclang and a config
/// file to produce a dozen declarations that change about once a year, and the
/// generated output would still have to be reviewed. The drift it protects
/// against is covered instead by a test that resolves every symbol, which fails
/// loudly the moment the library and this file disagree.
///
/// Nothing above this file touches a `Pointer`. That is the whole point of
/// keeping it separate: ownership mistakes can only be made here, where they
/// are easy to look for.
final class VoxScriptaBindings {
  VoxScriptaBindings(DynamicLibrary library)
      : abiVersion =
            library.lookupFunction<Int32 Function(), int Function()>('vs_abi_version'),
        lastErrorCopy = library.lookupFunction<Pointer<Utf8> Function(),
            Pointer<Utf8> Function()>('vs_last_error_copy'),
        lastErrorJsonCopy = library.lookupFunction<Pointer<Utf8> Function(),
            Pointer<Utf8> Function()>('vs_last_error_json_copy'),
        jobStart = library.lookupFunction<
            Int64 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>),
            int Function(Pointer<Utf8>, Pointer<Utf8>,
                Pointer<Utf8>)>('vs_job_start'),
        jobState =
            library.lookupFunction<Int32 Function(Int64), int Function(int)>('vs_job_state'),
        jobFraction = library
            .lookupFunction<Double Function(Int64), double Function(int)>('vs_job_fraction'),
        jobDetailCopy = library.lookupFunction<Pointer<Utf8> Function(Int64),
            Pointer<Utf8> Function(int)>('vs_job_detail_copy'),
        jobErrorCopy = library.lookupFunction<Pointer<Utf8> Function(Int64),
            Pointer<Utf8> Function(int)>('vs_job_error_copy'),
        jobErrorJsonCopy = library.lookupFunction<Pointer<Utf8> Function(Int64),
            Pointer<Utf8> Function(int)>('vs_job_error_json_copy'),
        exportFilename = library.lookupFunction<
            Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>),
            Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>,
                Pointer<Utf8>)>('vs_export_filename'),
        diagnosticsReportCopy = library.lookupFunction<
            Pointer<Utf8> Function(Pointer<Utf8>),
            Pointer<Utf8> Function(
                Pointer<Utf8>)>('vs_diagnostics_report_copy'),
        jobCancel =
            library.lookupFunction<Int32 Function(Int64), int Function(int)>('vs_job_cancel'),
        jobRelease =
            library.lookupFunction<Void Function(Int64), void Function(int)>('vs_job_release'),
        export = library.lookupFunction<
            Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>,
                Pointer<Utf8>, Pointer<Pointer<Uint8>>, Pointer<Int64>),
            int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>,
                Pointer<Utf8>, Pointer<Pointer<Uint8>>,
                Pointer<Int64>)>('vs_export'),
        setDataDirectory = library.lookupFunction<
            Int32 Function(Pointer<Utf8>),
            int Function(Pointer<Utf8>)>('vs_set_data_directory'),
        libraryDefaultDirectory = library.lookupFunction<Pointer<Utf8> Function(),
            Pointer<Utf8> Function()>('vs_library_default_directory'),
        libraryList = library.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>),
            Pointer<Utf8> Function(Pointer<Utf8>)>('vs_library_list'),
        projectDelete = library.lookupFunction<
            Int32 Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>),
            int Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>)>('vs_project_delete'),
        jobOptionsDefaults = library.lookupFunction<Pointer<Utf8> Function(),
            Pointer<Utf8> Function()>('vs_job_options_defaults'),
        exportOptionsDefaults = library.lookupFunction<Pointer<Utf8> Function(),
            Pointer<Utf8> Function()>('vs_export_options_defaults'),
        projectSummary = library.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>),
            Pointer<Utf8> Function(Pointer<Utf8>)>('vs_project_summary'),
        capabilities = library.lookupFunction<Pointer<Utf8> Function(),
            Pointer<Utf8> Function()>('vs_capabilities'),
        recordingDirectory = library.lookupFunction<Pointer<Utf8> Function(),
            Pointer<Utf8> Function()>('vs_recording_directory'),
        recordingNewPath = library.lookupFunction<Pointer<Utf8> Function(),
            Pointer<Utf8> Function()>('vs_recording_new_path'),
        recordingStart = library.lookupFunction<Int64 Function(Pointer<Utf8>),
            int Function(Pointer<Utf8>)>('vs_recording_start'),
        recordingState = library
            .lookupFunction<Int32 Function(Int64), int Function(int)>('vs_recording_state'),
        recordingElapsed = library.lookupFunction<Double Function(Int64),
            double Function(int)>('vs_recording_elapsed'),
        recordingLevel = library.lookupFunction<Double Function(Int64),
            double Function(int)>('vs_recording_level'),
        recordingFailureCopy = library.lookupFunction<Pointer<Utf8> Function(Int64),
            Pointer<Utf8> Function(int)>('vs_recording_failure_copy'),
        recordingInputIsSilent = library.lookupFunction<Int32 Function(Int64),
            int Function(int)>('vs_recording_input_is_silent'),
        recordingPause = library
            .lookupFunction<Int32 Function(Int64), int Function(int)>('vs_recording_pause'),
        recordingResume = library
            .lookupFunction<Int32 Function(Int64), int Function(int)>('vs_recording_resume'),
        recordingFinish = library.lookupFunction<
            Int32 Function(Int64, Pointer<Pointer<Utf8>>),
            int Function(int, Pointer<Pointer<Utf8>>)>('vs_recording_finish'),
        recordingDiscard = library
            .lookupFunction<Int32 Function(Int64), int Function(int)>('vs_recording_discard'),
        passwordRules = library.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>),
            Pointer<Utf8> Function(Pointer<Utf8>)>('vs_password_rules'),
        emailLooksValid = library.lookupFunction<Int32 Function(Pointer<Utf8>),
            int Function(Pointer<Utf8>)>('vs_email_looks_valid'),
        entitlementState = library.lookupFunction<Pointer<Utf8> Function(),
            Pointer<Utf8> Function()>('vs_entitlement_state'),
        entitlementRecordSubscription =
            library.lookupFunction<Int32 Function(Pointer<Utf8>),
                int Function(Pointer<Utf8>)>('vs_entitlement_record_subscription'),
        entitlementClearSubscription = library
            .lookupFunction<Int32 Function(), int Function()>(
                'vs_entitlement_clear_subscription'),
        waveform = library.lookupFunction<
            Int32 Function(Pointer<Utf8>, Int32, Pointer<Pointer<Uint8>>,
                Pointer<Int64>),
            int Function(Pointer<Utf8>, int, Pointer<Pointer<Uint8>>,
                Pointer<Int64>)>('vs_waveform'),
        bytesFree = library
            .lookupFunction<Void Function(Pointer<Uint8>), void Function(Pointer<Uint8>)>(
                'vs_bytes_free'),
        stringFree = library
            .lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>(
                'vs_string_free');

  final int Function() abiVersion;
  final Pointer<Utf8> Function() lastErrorCopy;
  final Pointer<Utf8> Function() lastErrorJsonCopy;
  final int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>) jobStart;
  final int Function(int) jobState;
  final double Function(int) jobFraction;
  final Pointer<Utf8> Function(int) jobDetailCopy;
  final Pointer<Utf8> Function(int) jobErrorCopy;
  final Pointer<Utf8> Function(int) jobErrorJsonCopy;
  final Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)
      exportFilename;
  final Pointer<Utf8> Function(Pointer<Utf8>) diagnosticsReportCopy;
  final int Function(int) jobCancel;
  final void Function(int) jobRelease;
  final int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>,
      Pointer<Pointer<Uint8>>, Pointer<Int64>) export;
  /// Tells the engine where it may write. Must be called before anything
  /// else, and on Android it must be called at all: the engine's default is
  /// the platform application-support directory, which resolves there to a
  /// read-only path that does not exist.
  final int Function(Pointer<Utf8>) setDataDirectory;

  final Pointer<Utf8> Function() libraryDefaultDirectory;
  final Pointer<Utf8> Function(Pointer<Utf8>) libraryList;
  final int Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>) projectDelete;
  final Pointer<Utf8> Function() jobOptionsDefaults;
  final Pointer<Utf8> Function() exportOptionsDefaults;
  final Pointer<Utf8> Function(Pointer<Utf8>) projectSummary;
  final Pointer<Utf8> Function() capabilities;
  final int Function(Pointer<Utf8>, int, Pointer<Pointer<Uint8>>, Pointer<Int64>)
      waveform;
  final Pointer<Utf8> Function(Pointer<Utf8>) passwordRules;
  final int Function(Pointer<Utf8>) emailLooksValid;
  final Pointer<Utf8> Function() entitlementState;
  final int Function(Pointer<Utf8>) entitlementRecordSubscription;
  final int Function() entitlementClearSubscription;
  final Pointer<Utf8> Function() recordingDirectory;
  final Pointer<Utf8> Function() recordingNewPath;
  final int Function(Pointer<Utf8>) recordingStart;
  final int Function(int) recordingState;
  final double Function(int) recordingElapsed;
  final double Function(int) recordingLevel;
  final Pointer<Utf8> Function(int) recordingFailureCopy;
  final int Function(int) recordingInputIsSilent;
  final int Function(int) recordingPause;
  final int Function(int) recordingResume;
  final int Function(int, Pointer<Pointer<Utf8>>) recordingFinish;
  final int Function(int) recordingDiscard;
  final void Function(Pointer<Uint8>) bytesFree;
  final void Function(Pointer<Utf8>) stringFree;

  /// Reads a string the library allocated and releases it.
  ///
  /// Every `*_copy` result goes through here, so the pairing of read and free
  /// exists in one place. The library's own free is used rather than
  /// `calloc.free`, because a Windows DLL and its host can hold separate C
  /// runtime heaps and freeing across them corrupts both.
  String? takeString(Pointer<Utf8> pointer) {
    if (pointer == nullptr) return null;
    try {
      return pointer.toDartString();
    } finally {
      stringFree(pointer);
    }
  }

  /// The last failure on this thread, or null.
  String? lastError() => takeString(lastErrorCopy());

  /// The same failure as a [EngineFailure], or null.
  ///
  /// Prefer this over [lastError] anywhere the text reaches a person: the
  /// engine's sentence is English off Apple and always will be, so a
  /// localized interface has to build its own from [EngineFailure.code].
  EngineFailure? lastFailure() => EngineFailure.parse(takeString(lastErrorJsonCopy()));

  /// A [VoxScriptaException] for the last failure on this thread, carrying the
  /// structured form beside the engine's sentence.
  VoxScriptaException exception(String fallback, {int? code}) {
    final failure = lastFailure();
    return VoxScriptaException(
      failure?.message.isNotEmpty == true ? failure!.message : (lastError() ?? fallback),
      code: code,
      failure: failure,
    );
  }

  /// Why a job failed, structured, or null if it has not.
  EngineFailure? jobFailure(int handle) =>
      EngineFailure.parse(takeString(jobErrorJsonCopy(handle)));

  /// What a rendered export should be called.
  ///
  /// Ask rather than build the name here. The convention lives in the engine
  /// — the separator is an em dash with spaces — and a second copy of it
  /// drifts the first time it changes, with nothing comparing the two.
  ///
  /// A diagnostics report, as text a person reads before deciding to send it.
  ///
  /// Nothing is transmitted by the engine and nothing can be: there is no
  /// network entitlement in the build. Show this text, then hand it to the
  /// platform's share sheet and let the person choose where it goes.
  ///
  /// It carries no transcript, no audio and no paths. Pass an empty
  /// [projectPath] for a report about the installation alone.
  String? diagnosticsReport({String projectPath = ''}) {
    final ptr = projectPath.toNativeUtf8();
    try {
      return takeString(diagnosticsReportCopy(ptr));
    } finally {
      calloc.free(ptr);
    }
  }

  /// Null for an unknown variant or format; [lastError] says which.
  String? exportFilenameFor({
    required String base,
    required String variant,
    required String format,
  }) {
    final basePtr = base.toNativeUtf8();
    final variantPtr = variant.toNativeUtf8();
    final formatPtr = format.toNativeUtf8();
    try {
      return takeString(exportFilename(basePtr, variantPtr, formatPtr));
    } finally {
      calloc.free(basePtr);
      calloc.free(variantPtr);
      calloc.free(formatPtr);
    }
  }
}

/// A failure the engine reports, in a form an interface can translate.
///
/// The engine cannot localize its own messages away from Apple's platforms:
/// `String(localized:)` is absent from swift-corelibs-foundation, and the
/// shim behind it is reached only after interpolation, when the lookup key no
/// longer exists. So the engine reports what happened and the values
/// involved, and whoever knows the reader's language writes the sentence.
class EngineFailure {
  const EngineFailure({
    required this.code,
    required this.message,
    required this.details,
  });

  /// A stable identifier for the error case, such as `sourceChanged`. Map
  /// this to your own wording.
  final String code;

  /// The engine's own sentence. English off Apple. Show it only when [code]
  /// is one you have no wording for — English beats a blank dialog.
  final String message;

  /// The values the sentence would have interpolated, unformatted. Numbers
  /// are plain digits, so apply the reader's locale yourself.
  final Map<String, String> details;

  static EngineFailure? parse(String? json) {
    if (json == null) return null;
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map) return null;
      final rawDetails = decoded['details'];
      return EngineFailure(
        code: decoded['code'] as String? ?? 'invalidArgument',
        message: decoded['message'] as String? ?? '',
        details: rawDetails is Map
            ? rawDetails.map((k, v) => MapEntry('$k', '$v'))
            : const <String, String>{},
      );
    } on FormatException {
      // A failure that cannot be parsed must not become a second, different
      // failure: the caller is already handling one.
      return null;
    }
  }
}
