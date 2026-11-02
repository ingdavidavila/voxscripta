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

/// One project, as the library lists it.
class ProjectEntry {
  const ProjectEntry({
    required this.id,
    required this.path,
    required this.displayName,
    required this.duration,
    required this.state,
    required this.modifiedAt,
  });

  factory ProjectEntry.fromJson(Map<String, Object?> json) => ProjectEntry(
        id: json['id'] as String? ?? '',
        path: json['path'] as String? ?? '',
        displayName: json['displayName'] as String? ?? '',
        duration: Duration(
            microseconds:
                (((json['durationSeconds'] as num?) ?? 0) * 1e6).round()),
        state: JobState.values.firstWhere(
          (candidate) => candidate.name == json['state'],
          orElse: () => JobState.unknownHandle,
        ),
        modifiedAt: DateTime.fromMillisecondsSinceEpoch(
            (((json['modifiedAt'] as num?) ?? 0) * 1000).round()),
      );

  final String id;
  final String path;
  final String displayName;
  final Duration duration;

  /// Reads `complete` for every project with a readable manifest. The real
  /// state lives in each project's job store, and opening one per row would
  /// cost a database open per entry. The SwiftUI library pane says the same
  /// thing, deliberately: both interfaces agreeing beats each guessing.
  final JobState state;

  final DateTime modifiedAt;

  @override
  String toString() => 'ProjectEntry($displayName, $duration, ${state.name})';
}

/// Settings for a job.
///
/// Every field is nullable and a null means "the engine's default", so an
/// interface sets only what the user changed. Read the defaults from
/// [VoxScriptaEngine.jobOptionDefaults] rather than writing them here — a
/// default in an interface is a rule the other interface cannot see.
class JobOptions {
  const JobOptions({
    this.locale,
    this.detectLanguage,
    this.concurrency,
    this.silence,
    this.chunking,
    this.clean,
    this.polish,
    this.polishEnabled,
    this.polishBackend,
    this.keepIntermediates,
  });

  final String? locale;
  final bool? detectLanguage;
  final int? concurrency;

  /// Passed through as the engine encodes them, so that adding a silence
  /// parameter does not mean changing this package. The shapes are whatever
  /// `jobOptionDefaults` reports.
  final Map<String, Object?>? silence;
  final Map<String, Object?>? chunking;
  final Map<String, Object?>? clean;
  final Map<String, Object?>? polish;

  /// False stops after CLEAN.
  final bool? polishEnabled;

  /// `automatic`, `system` or `bundled`. A name the engine does not know is
  /// refused rather than substituted.
  final String? polishBackend;

  final bool? keepIntermediates;

  Map<String, Object?> toJson() => {
        if (locale != null) 'locale': locale,
        if (detectLanguage != null) 'detectLanguage': detectLanguage,
        if (concurrency != null) 'concurrency': concurrency,
        if (silence != null) 'silence': silence,
        if (chunking != null) 'chunking': chunking,
        if (clean != null) 'clean': clean,
        if (polish != null) 'polish': polish,
        if (polishEnabled != null) 'polishEnabled': polishEnabled,
        if (polishBackend != null) 'polishBackend': polishBackend,
        if (keepIntermediates != null) 'keepIntermediates': keepIntermediates,
      };
}

/// Settings for an export.
class ExportOptions {
  const ExportOptions({
    this.includeTimestamps,
    this.includeSpeakerLabels,
    this.maximumCueLength,
  });

  final bool? includeTimestamps;
  final bool? includeSpeakerLabels;

  /// Maximum characters per subtitle cue.
  final int? maximumCueLength;

  Map<String, Object?> toJson() => {
        if (includeTimestamps != null) 'includeTimestamps': includeTimestamps,
        if (includeSpeakerLabels != null) 'includeSpeakerLabels': includeSpeakerLabels,
        if (maximumCueLength != null) 'maximumCueLength': maximumCueLength,
      };
}

/// One transcript that exists on disk.
class VariantSummary {
  const VariantSummary({
    required this.variant,
    required this.words,
    required this.segments,
  });

  factory VariantSummary.fromJson(Map<String, Object?> json) => VariantSummary(
        variant: TranscriptVariant.values.firstWhere(
          (candidate) => candidate.wireName == json['variant'],
          orElse: () => TranscriptVariant.verbatim,
        ),
        words: (json['words'] as num?)?.toInt() ?? 0,
        segments: (json['segments'] as num?)?.toInt() ?? 0,
      );

  final TranscriptVariant variant;
  final int words;
  final int segments;
}

/// What POLISH did with one sentence it did not simply accept.
class FlaggedSentence {
  const FlaggedSentence({
    required this.disposition,
    required this.original,
    required this.revised,
    required this.reasons,
  });

  factory FlaggedSentence.fromJson(Map<String, Object?> json) => FlaggedSentence(
        disposition: PolishDisposition.fromWire(json['disposition'] as String?),
        original: json['original'] as String? ?? '',
        revised: json['revised'] as String? ?? '',
        reasons: ((json['reasons'] as List<Object?>?) ?? const [])
            .map((reason) => reason.toString())
            .toList(growable: false),
      );

  final PolishDisposition disposition;
  final String original;
  final String revised;

  /// Which gauntlet checks failed, in the engine's own words.
  final List<String> reasons;
}

/// What happened to a sentence in the polish pass.
enum PolishDisposition {
  accepted,
  acceptedAfterRetry,

  /// Validation failed twice. The CLEAN text stands.
  fellBackToClean,

  /// The model errored. The CLEAN text stands.
  modelFailed,

  unknown;

  static PolishDisposition fromWire(String? name) => switch (name) {
        'accepted' => PolishDisposition.accepted,
        'acceptedAfterRetry' => PolishDisposition.acceptedAfterRetry,
        'fellBackToClean' => PolishDisposition.fellBackToClean,
        'modelFailed' => PolishDisposition.modelFailed,
        _ => PolishDisposition.unknown,
      };

  /// Whether the model's rewrite was used. False means the CLEAN sentence
  /// survived, which is the gauntlet doing its job rather than a failure.
  bool get keptModelText => switch (this) {
        PolishDisposition.accepted || PolishDisposition.acceptedAfterRetry => true,
        _ => false,
      };
}

/// The polish review, as the transcript screen shows it.
class PolishReview {
  const PolishReview({
    required this.ran,
    required this.skipReason,
    required this.accepted,
    required this.acceptedAfterRetry,
    required this.keptClean,
    required this.flagged,
  });

  factory PolishReview.fromJson(Map<String, Object?> json) => PolishReview(
        ran: json['ran'] as bool? ?? false,
        skipReason: json['skipReason'] as String?,
        accepted: (json['accepted'] as num?)?.toInt() ?? 0,
        acceptedAfterRetry: (json['acceptedAfterRetry'] as num?)?.toInt() ?? 0,
        keptClean: (json['keptClean'] as num?)?.toInt() ?? 0,
        flagged: ((json['flagged'] as List<Object?>?) ?? const [])
            .cast<Map<String, Object?>>()
            .map(FlaggedSentence.fromJson)
            .toList(growable: false),
      );

  final bool ran;

  /// Why POLISH declined, when it did. Shown verbatim — §26 asks that a
  /// missing polished transcript never be unexplained.
  final String? skipReason;

  final int accepted;
  final int acceptedAfterRetry;
  final int keptClean;

  /// Only the sentences worth reading: retries, and anything where the CLEAN
  /// text had to stand. Plain acceptances are counted, not carried.
  final List<FlaggedSentence> flagged;

  int get total => accepted + acceptedAfterRetry + keptClean;
  bool get hasSomethingToShow => ran || skipReason != null;
}

/// What is known about a project's audio, filled in as the stages that produce
/// it run. A null is "not yet", not "none".
class AudioFacts {
  const AudioFacts({
    required this.duration,
    required this.speechRegions,
    required this.speechFraction,
    required this.waveformBuckets,
    required this.polishEstimate,
    this.speechSpans = const [],
  });

  factory AudioFacts.fromJson(Map<String, Object?> json) => AudioFacts(
        duration: Duration(
            microseconds:
                (((json['durationSeconds'] as num?) ?? 0) * 1e6).round()),
        speechRegions: (json['speechRegions'] as num?)?.toInt(),
        speechFraction: (json['speechFraction'] as num?)?.toDouble(),
        waveformBuckets: (json['waveformBuckets'] as num?)?.toInt(),
        speechSpans: [
          for (final span in (json['speechSpans'] as List<Object?>?) ?? const [])
            if (span is List<Object?> && span.length >= 2)
              (
                ((span[0] as num?) ?? 0).toDouble(),
                ((span[1] as num?) ?? 0).toDouble(),
              ),
        ],
        polishEstimate: (json['polishEstimateSeconds'] as num?) == null
            ? null
            : Duration(
                microseconds:
                    ((json['polishEstimateSeconds']! as num) * 1e6).round()),
      );

  final Duration duration;

  /// Null until silence detection has run.
  final int? speechRegions;
  final double? speechFraction;

  /// Null until the analysis stage has produced a waveform.
  final int? waveformBuckets;

  /// Where speech was detected, in seconds. Empty until silence detection has
  /// run. The spans and not just the fraction, because an interface drawing
  /// them needs to know where.
  final List<(double start, double end)> speechSpans;

  /// Roughly how long POLISH will take, at the engine's measured rate. The
  /// rate is a measurement and therefore the engine's to apply.
  final Duration? polishEstimate;

  bool get hasWaveform => (waveformBuckets ?? 0) > 0;
}

/// Everything the transcript and processing screens need that is not text.
class ProjectSummary {
  const ProjectSummary({
    required this.variants,
    required this.polish,
    this.audio = const AudioFacts(
      duration: Duration.zero,
      speechRegions: null,
      speechFraction: null,
      waveformBuckets: null,
      polishEstimate: null,
    ),
  });

  factory ProjectSummary.fromJson(Map<String, Object?> json) => ProjectSummary(
        variants: ((json['variants'] as List<Object?>?) ?? const [])
            .cast<Map<String, Object?>>()
            .map(VariantSummary.fromJson)
            .toList(growable: false),
        polish: PolishReview.fromJson(
            (json['polish'] as Map<String, Object?>?) ?? const {}),
        audio: AudioFacts.fromJson(
            (json['audio'] as Map<String, Object?>?) ?? const {}),
      );

  /// Only the transcripts that exist. A project still being processed reports
  /// fewer than three, and an unfinished one reports none.
  final List<VariantSummary> variants;

  final PolishReview polish;
  final AudioFacts audio;

  VariantSummary? forVariant(TranscriptVariant variant) {
    for (final candidate in variants) {
      if (candidate.variant == variant) return candidate;
    }
    return null;
  }
}

/// One transcription language the interface may offer.
class LocaleOption {
  const LocaleOption({
    required this.identifier,
    required this.displayName,
    required this.hasTextSupport,
    required this.polishValidated,
  });

  factory LocaleOption.fromJson(Map<String, Object?> json) => LocaleOption(
        identifier: json['identifier'] as String? ?? '',
        displayName: json['displayName'] as String? ?? '',
        hasTextSupport: json['hasTextSupport'] as bool? ?? false,
        polishValidated: json['polishValidated'] as bool? ?? false,
      );

  final String identifier;
  final String displayName;

  /// Whether CLEAN and POLISH understand this language. Transcription works
  /// either way; the text stages do not, because applying one language's
  /// filler list to another deletes real words.
  final bool hasTextSupport;

  /// Whether POLISH is permitted in it. A language with no polarity lexicon
  /// has no defence against a reversed meaning, so the gauntlet refuses it.
  final bool polishValidated;
}

/// Which model POLISH would use if a job started now.
class PolishCapability {
  const PolishCapability({
    required this.systemModelAvailable,
    required this.bundledModel,
    required this.effective,
    required this.unavailableReason,
  });

  factory PolishCapability.fromJson(Map<String, Object?> json) => PolishCapability(
        systemModelAvailable: json['systemModelAvailable'] as bool? ?? false,
        bundledModel: json['bundledModel'] as String?,
        effective: json['effective'] as String?,
        unavailableReason: json['unavailableReason'] as String?,
      );

  final bool systemModelAvailable;

  /// The bundled model's name, or null when this build ships none.
  final String? bundledModel;

  /// What would actually run, in the same words the provenance records.
  final String? effective;

  /// Why nothing would run. Exactly one of this and [effective] is set.
  final String? unavailableReason;

  bool get isAvailable => effective != null;
}

/// What this build on this machine can do.
class Capabilities {
  const Capabilities({required this.locales, required this.polish});

  factory Capabilities.fromJson(Map<String, Object?> json) => Capabilities(
        locales: ((json['locales'] as List<Object?>?) ?? const [])
            .cast<Map<String, Object?>>()
            .map(LocaleOption.fromJson)
            .toList(growable: false),
        polish: PolishCapability.fromJson(
            (json['polish'] as Map<String, Object?>?) ?? const {}),
      );

  final List<LocaleOption> locales;
  final PolishCapability polish;

  LocaleOption? forIdentifier(String identifier) {
    for (final option in locales) {
      if (option.identifier == identifier) return option;
    }
    return null;
  }
}
