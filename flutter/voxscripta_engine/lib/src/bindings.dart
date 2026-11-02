import 'dart:ffi';
import 'package:ffi/ffi.dart';

/// The seventeen symbols of `ffi/voxscripta.h`, and nothing else.
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
        bytesFree = library
            .lookupFunction<Void Function(Pointer<Uint8>), void Function(Pointer<Uint8>)>(
                'vs_bytes_free'),
        stringFree = library
            .lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>(
                'vs_string_free');

  final int Function() abiVersion;
  final Pointer<Utf8> Function() lastErrorCopy;
  final int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>) jobStart;
  final int Function(int) jobState;
  final double Function(int) jobFraction;
  final Pointer<Utf8> Function(int) jobDetailCopy;
  final Pointer<Utf8> Function(int) jobErrorCopy;
  final int Function(int) jobCancel;
  final void Function(int) jobRelease;
  final int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>,
      Pointer<Pointer<Uint8>>, Pointer<Int64>) export;
  final Pointer<Utf8> Function() libraryDefaultDirectory;
  final Pointer<Utf8> Function(Pointer<Utf8>) libraryList;
  final int Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>) projectDelete;
  final Pointer<Utf8> Function() jobOptionsDefaults;
  final Pointer<Utf8> Function() exportOptionsDefaults;
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
}
