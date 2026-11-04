import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:voxscripta_engine/voxscripta_engine.dart';

/// What the transcript screen needs from the engine.
///
/// A seam for the same narrow reason the library has one: the widget tests are
/// about the screen, and the boundary is tested properly in
/// `voxscripta_engine` against a real library.
abstract interface class TranscriptSource {
  ProjectSummary summary(String projectPath);

  Future<Uint8List> export({
    required String projectPath,
    required TranscriptVariant variant,
    required ExportFormat format,
    ExportOptions? options,
  });
}

class EngineTranscriptSource implements TranscriptSource {
  const EngineTranscriptSource(this._engine);

  final VoxScriptaEngine _engine;

  @override
  ProjectSummary summary(String projectPath) => _engine.summary(projectPath);

  @override
  Future<Uint8List> export({
    required String projectPath,
    required TranscriptVariant variant,
    required ExportFormat format,
    ExportOptions? options,
  }) =>
      _engine.export(
        projectPath: projectPath,
        variant: variant,
        format: format,
        options: options,
      );
}

/// The transcript screen's state.
///
/// The text on screen is the engine's own plain-text export rather than
/// anything assembled here. Paragraph breaks come from the silence parameters
/// the project was built with, which makes them a rule — and a second
/// implementation of that rule in Dart would be a second answer waiting to
/// disagree with the SwiftUI one.
class TranscriptModel extends ChangeNotifier {
  TranscriptModel({
    required TranscriptSource source,
    required this.projectPath,
    required this.displayName,
    TranscriptVariant preferred = TranscriptVariant.clean,
  })  : _source = source,
        _preferred = preferred;

  factory TranscriptModel.of(
    VoxScriptaEngine engine, {
    required String projectPath,
    required String displayName,
    TranscriptVariant preferred = TranscriptVariant.clean,
  }) =>
      TranscriptModel(
        source: EngineTranscriptSource(engine),
        projectPath: projectPath,
        displayName: displayName,
        preferred: preferred,
      );

  final TranscriptSource _source;
  final String projectPath;
  final String displayName;
  final TranscriptVariant _preferred;

  ProjectSummary? _summary;
  TranscriptVariant? _selected;
  String _text = '';
  bool _isLoading = true;
  String? _error;
  bool _showsReview = false;
  bool _includeTimestamps = false;
  String? _notice;

  ProjectSummary? get summary => _summary;
  TranscriptVariant? get selected => _selected;
  String get text => _text;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get showsReview => _showsReview;
  bool get includeTimestamps => _includeTimestamps;

  /// A short confirmation — "Copied", "Saved to …" — that fades on its own.
  String? get notice => _notice;

  List<TranscriptVariant> get availableVariants =>
      (_summary?.variants ?? const []).map((v) => v.variant).toList(growable: false);

  VariantSummary? get selectedSummary =>
      _selected == null ? null : _summary?.forVariant(_selected!);

  PolishReview? get polish => _summary?.polish;

  Future<void> load() async {
    _isLoading = true;
    notifyListeners();
    try {
      final summary = _source.summary(projectPath);
      _summary = summary;
      _error = null;

      final available = summary.variants.map((v) => v.variant).toList();
      // The preferred variant when it exists, otherwise the best one that
      // does — a project that stopped after CLEAN has no polished transcript,
      // and showing an empty pane would read as a bug.
      _selected = available.contains(_preferred)
          ? _preferred
          : available.isEmpty
              ? null
              : available.last;
      await _loadText();
    } on VoxScriptaException catch (failure) {
      _error = failure.message;
      _summary = null;
      _text = '';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> select(TranscriptVariant variant) async {
    if (_selected == variant) return;
    _selected = variant;
    notifyListeners();
    await _loadText();
    notifyListeners();
  }

  Future<void> _loadText() async {
    final variant = _selected;
    if (variant == null) {
      _text = '';
      return;
    }
    try {
      final bytes = await _source.export(
        projectPath: projectPath,
        variant: variant,
        format: ExportFormat.plainText,
      );
      _text = utf8.decode(bytes);
      _error = null;
    } on VoxScriptaException catch (failure) {
      _text = '';
      _error = failure.message;
    }
  }

  void toggleReview() {
    _showsReview = !_showsReview;
    notifyListeners();
  }

  void setIncludeTimestamps(bool value) {
    if (_includeTimestamps == value) return;
    _includeTimestamps = value;
    notifyListeners();
  }

  /// Renders the current variant in [format], for saving or copying.
  Future<Uint8List> render(ExportFormat format) async {
    final variant = _selected;
    if (variant == null) {
      throw const VoxScriptaException('there is no transcript to export');
    }
    return _source.export(
      projectPath: projectPath,
      variant: variant,
      format: format,
      options: ExportOptions(includeTimestamps: _includeTimestamps),
    );
  }

  void showNotice(String message) {
    _notice = message;
    notifyListeners();
  }

  void clearNotice() {
    if (_notice == null) return;
    _notice = null;
    notifyListeners();
  }
}
