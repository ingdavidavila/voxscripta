/// Dart bindings for the Vox Scripta engine.
///
/// The engine is a Swift library behind a C ABI; this package is the whole of
/// what Dart needs to drive it. It contains no rules of its own — not one
/// threshold, not one piece of transcript formatting — because a rule that
/// lived here would be a rule the SwiftUI interface could not see, and the two
/// interfaces would start to disagree. Everything is a call into the engine.
library;

export 'src/engine.dart' show VoxScriptaEngine;
export 'src/job.dart' show Job;
export 'src/model.dart'
    show
        AudioFacts,
        Capabilities,
        ExportFormat,
        ExportOptions,
        FlaggedSentence,
        LocaleOption,
        JobOptions,
        JobProgress,
        JobState,
        PolishCapability,
        PolishDisposition,
        PolishReview,
        ProjectEntry,
        ProjectSummary,
        TranscriptVariant,
        VariantSummary,
        VoxScriptaException;
