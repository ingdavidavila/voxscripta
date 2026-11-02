import 'package:flutter/foundation.dart';
import 'package:voxscripta_engine/voxscripta_engine.dart';

import 'settings_store.dart';

/// What the settings screen needs from the engine.
abstract interface class SettingsSource {
  Map<String, Object?> get jobDefaults;
  Capabilities capabilities();
  String get libraryDirectory;
}

class EngineSettingsSource implements SettingsSource {
  const EngineSettingsSource(this._engine);

  final VoxScriptaEngine _engine;

  @override
  Map<String, Object?> get jobDefaults => _engine.jobOptionDefaults;

  @override
  Capabilities capabilities() => _engine.capabilities();

  @override
  String get libraryDirectory => _engine.defaultLibraryDirectory;
}

/// The settings screen's state.
///
/// Every value starts as the engine's own default and is overridden only where
/// the user has changed something. That is the whole design: a settings screen
/// with its own idea of the default silence margin is a rule living in an
/// interface, and the moment the engine's changes the two disagree.
class SettingsModel extends ChangeNotifier {
  SettingsModel({required SettingsSource source, SettingsStore? store})
      : _source = source,
        _store = store;

  factory SettingsModel.of(VoxScriptaEngine engine) {
    final source = EngineSettingsSource(engine);
    return SettingsModel(
      source: source,
      store: SettingsStore(directory: source.libraryDirectory),
    );
  }

  final SettingsSource _source;
  final SettingsStore? _store;

  Map<String, Object?> _defaults = const {};
  Map<String, Object?> _overrides = {};
  Capabilities? _capabilities;
  String? _error;
  bool _isLoading = true;

  bool get isLoading => _isLoading;

  /// Where projects are kept, as the engine reports it.
  String get libraryDirectory => _source.libraryDirectory;
  String? get error => _error;
  Capabilities? get capabilities => _capabilities;

  /// The engine's defaults, for showing what "default" means.
  Map<String, Object?> get defaults => _defaults;

  void load() {
    _isLoading = true;
    notifyListeners();
    try {
      _defaults = _source.jobDefaults;
      _capabilities = _source.capabilities();
      _overrides = Map<String, Object?>.from(_store?.load() ?? const {});
      _error = null;
    } on VoxScriptaException catch (failure) {
      _error = failure.message;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // ── Reading ──────────────────────────────────────────────────────────────

  T _value<T>(String key, T fallback) {
    final override = _overrides[key];
    if (override is T) return override;
    final engineDefault = _defaults[key];
    if (engineDefault is T) return engineDefault;
    return fallback;
  }

  double _nested(String group, String key, double fallback) {
    final overridden = (_overrides[group] as Map<String, Object?>?)?[key];
    if (overridden is num) return overridden.toDouble();
    final engineDefault = (_defaults[group] as Map<String, Object?>?)?[key];
    if (engineDefault is num) return engineDefault.toDouble();
    return fallback;
  }

  bool _nestedFlag(String group, String key, bool fallback) {
    final overridden = (_overrides[group] as Map<String, Object?>?)?[key];
    if (overridden is bool) return overridden;
    final engineDefault = (_defaults[group] as Map<String, Object?>?)?[key];
    if (engineDefault is bool) return engineDefault;
    return fallback;
  }

  String get locale => _value('locale', 'en-US');
  bool get detectLanguage => _value('detectLanguage', true);
  int get concurrency => _value('concurrency', 4);
  bool get keepIntermediates => _value('keepIntermediates', false);
  bool get polishEnabled => _value('polishEnabled', true);
  String get polishBackend => _value('polishBackend', 'automatic');

  double get silenceMarginDB => _nested('silence', 'marginDB', 6);
  double get minimumSilenceSeconds =>
      _nested('silence', 'minSilenceDuration', 0.5);
  double get padTrailSeconds => _nested('silence', 'padTrail', 0.2);
  double get maximumChunkSeconds => _nested('chunking', 'maxDuration', 300);

  bool get removeFillers => _nestedFlag('clean', 'removeFillers', true);
  bool get collapseRepetitions =>
      _nestedFlag('clean', 'collapseRepetitions', true);
  bool get dropLowConfidence => _nestedFlag('clean', 'dropLowConfidence', true);

  /// Whether POLISH is permitted in the chosen language.
  ///
  /// The engine's answer, not a guess: a language with no polarity lexicon has
  /// no defence against a reversed meaning.
  bool get polishSupportedHere =>
      _capabilities?.forIdentifier(locale)?.polishValidated ?? false;

  bool get textStagesSupportedHere =>
      _capabilities?.forIdentifier(locale)?.hasTextSupport ?? false;

  // ── Writing ──────────────────────────────────────────────────────────────

  void set(String key, Object? value) {
    if (value == _defaults[key]) {
      _overrides.remove(key);
    } else {
      _overrides[key] = value;
    }
    _persist();
  }

  void setNested(String group, String key, Object? value) {
    final current = Map<String, Object?>.from(
        (_overrides[group] as Map<String, Object?>?) ??
            (_defaults[group] as Map<String, Object?>?) ??
            const {});
    current[key] = value;
    _overrides[group] = current;
    _persist();
  }

  /// Puts everything back to the engine's defaults.
  void reset() {
    _overrides = {};
    _persist();
  }

  bool get hasOverrides => _overrides.isNotEmpty;

  /// The settings as the ABI takes them: only what the user changed.
  JobOptions toJobOptions() => JobOptions(
        locale: _overrides.containsKey('locale') ? locale : null,
        detectLanguage:
            _overrides.containsKey('detectLanguage') ? detectLanguage : null,
        concurrency: _overrides.containsKey('concurrency') ? concurrency : null,
        silence: _overrides['silence'] as Map<String, Object?>?,
        chunking: _overrides['chunking'] as Map<String, Object?>?,
        clean: _overrides['clean'] as Map<String, Object?>?,
        polishEnabled:
            _overrides.containsKey('polishEnabled') ? polishEnabled : null,
        polishBackend:
            _overrides.containsKey('polishBackend') ? polishBackend : null,
        keepIntermediates: _overrides.containsKey('keepIntermediates')
            ? keepIntermediates
            : null,
      );

  void _persist() {
    _store?.save(_overrides);
    notifyListeners();
  }
}
