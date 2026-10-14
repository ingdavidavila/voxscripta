import SwiftUI

/// Every string the interface shows, in one place.
///
/// SwiftUI localizes `Text("…")` and `.help("…")` only when the argument is a
/// *literal*. Many of this app's tooltips were assembled with `+` across
/// several lines to keep them readable, which made them `String` rather than
/// `LocalizedStringKey` and therefore invisible to translation. Collecting them
/// here keeps the view code short while leaving each one a single literal: the
/// multi-line form with a trailing backslash joins the lines without inserting
/// a newline, so the value is one sentence and the source stays inside the
/// margin.
///
/// The English text is also the key. That makes `en.lproj` unnecessary — an
/// untranslated string falls back to readable English rather than to a dotted
/// identifier — and it means a translator receives sentences rather than
/// symbols. The cost is that editing English copy invalidates its translation,
/// which is the right trade while there are two languages and one author.
/// Main-actor isolated because `LocalizedStringKey` is not `Sendable` and
/// these are only ever read while building a view.
@MainActor
enum Strings {

    // MARK: - Import

    static let dropRecording: LocalizedStringKey = "Drop a recording"
    static let dropSubtitle: LocalizedStringKey = "Interviews, meetings, lectures — any length."
    static let chooseAudio: LocalizedStringKey = "Choose Audio…"
    static let chooseAudioHelp: LocalizedStringKey = """
        Pick an audio file to transcribe. Vox Scripta reads it and never writes to it.
        """
    static let neverLeaves: LocalizedStringKey = "Your audio never leaves this Mac"
    static let originalUnmodified: LocalizedStringKey = "The original file is never modified."

    // MARK: - Library and toolbar

    static let openAudio: LocalizedStringKey = "Open Audio"
    static let openAudioHelp: LocalizedStringKey = """
        Choose a recording to transcribe. The original file is never modified.
        """
    static let stop: LocalizedStringKey = "Stop"
    static let stopHelp: LocalizedStringKey = """
        Stop processing. Finished work is kept and can be resumed.
        """
    static let onThisMac: LocalizedStringKey = "On this Mac"
    static let privacyBadgeHelp: LocalizedStringKey = """
        Vox Scripta processes audio entirely on this Mac. It ships without network \
        access and cannot upload anything.
        """
    static let recordings: LocalizedStringKey = "Recordings"
    static let noRecordings: LocalizedStringKey = "No recordings yet"
    static let noRecordingsDetail: LocalizedStringKey = "Drop an audio file to begin."
    static let showInFinder: LocalizedStringKey = "Show in Finder"
    static let showInFinderHelp: LocalizedStringKey = "Reveal this recording's project folder."
    static let deleteEllipsis: LocalizedStringKey = "Delete…"
    static let deleteHelp: LocalizedStringKey = """
        Move this recording and its transcripts to the Trash.
        """

    // MARK: - Dialogs

    static let somethingWrong: LocalizedStringKey = "Something went wrong"
    static let ok: LocalizedStringKey = "OK"
    static let dismissHelp: LocalizedStringKey = "Dismiss this message."
    static let moveToTrash: LocalizedStringKey = "Move to Trash"
    static let moveToTrashHelp: LocalizedStringKey = """
        Move this recording and its transcripts to the Trash. You can put them back from there.
        """
    static let cancel: LocalizedStringKey = "Cancel"
    static let keepRecordingHelp: LocalizedStringKey = "Keep this recording."

    // MARK: - Processing

    static let readingAudio: LocalizedStringKey = "Reading audio…"

    // MARK: - Transcript

    static let review: LocalizedStringKey = "Review"
    static let reviewHelp: LocalizedStringKey = """
        Show what the polish pass changed, and what it refused to change.
        """
    static let copy: LocalizedStringKey = "Copy"
    static let download: LocalizedStringKey = "Download"
    static let saveAs: LocalizedStringKey = "Save As"
    static let includeTimestamps: LocalizedStringKey = "Include timestamps"
    static let includeTimestampsHelp: LocalizedStringKey = """
        Write each segment's start time alongside its text. Subtitle formats always \
        carry timings.
        """
    static let saveEveryVariant: LocalizedStringKey = "Save Every Variant…"
    static let saveEveryVariantHelp: LocalizedStringKey = """
        Write the verbatim, clean and polished transcripts to one folder.
        """
    static let silenceRemovedAudio: LocalizedStringKey = "Audio with Silence Removed…"
    static let silenceRemovedAudioHelp: LocalizedStringKey = """
        Render a new audio file with the silences taken out. Your original recording \
        is left untouched.
        """
    static let polishDidNotRun: LocalizedStringKey = "Polish did not run"
    static let polishReview: LocalizedStringKey = "Polish review"
    static let accepted: LocalizedStringKey = "Accepted"
    static let acceptedAfterRetry: LocalizedStringKey = "Accepted after retry"
    static let keptCleanText: LocalizedStringKey = "Kept the clean text"
    static let modelCouldNotRun: LocalizedStringKey = "The model could not run"
    static let everySentencePassed: LocalizedStringKey = """
        Every sentence passed on the first attempt.
        """

    // MARK: - Transcript variants

    static let verbatim: LocalizedStringKey = "Verbatim"
    static let clean: LocalizedStringKey = "Clean"
    static let polished: LocalizedStringKey = "Polished"
    static let verbatimExplanation: LocalizedStringKey = """
        Exactly what was said, including hesitations.
        """
    static let cleanExplanation: LocalizedStringKey = """
        Tidied by fixed rules. No language model was involved.
        """
    static let polishedExplanation: LocalizedStringKey = """
        Rewritten for readability, checked against the original.
        """

    // MARK: - Export formats

    static let formatPlainText: LocalizedStringKey = "Plain Text (.txt)"
    static let formatMarkdown: LocalizedStringKey = "Markdown (.md)"
    static let formatDocx: LocalizedStringKey = "Word (.docx)"
    static let formatSubRip: LocalizedStringKey = "Subtitles (.srt)"
    static let formatWebVTT: LocalizedStringKey = "Web Captions (.vtt)"
    static let explainPlainText: LocalizedStringKey = """
        Just the words, in a file any editor can open.
        """
    static let explainMarkdown: LocalizedStringKey = """
        Words with light formatting, for notes and documentation.
        """
    static let explainDocx: LocalizedStringKey = """
        A Word document, for sharing and further editing.
        """
    static let explainSubRip: LocalizedStringKey = """
        Timed subtitles, the format most video editors expect.
        """
    static let explainWebVTT: LocalizedStringKey = "Timed captions for the web."

    // MARK: - Settings: audio

    static var settingsAudio: LocalizedStringKey { "Audio" }
    static var silenceDetection: LocalizedStringKey { "Silence detection" }
    static var thresholdAboveNoise: LocalizedStringKey { "Threshold above noise floor" }
    static var thresholdHelp: LocalizedStringKey {
        """
        How far above the measured background noise a sound must be to count as \
        speech. Raise it for a noisy recording.
        """
    }
    static var shortestPause: LocalizedStringKey { "Shortest pause" }
    static var shortestPauseHelp: LocalizedStringKey {
        """
        A quiet stretch shorter than this is treated as part of the speech, not as \
        a pause.
        """
    }
    static var paddingAfterSpeech: LocalizedStringKey { "Padding after speech" }
    static var paddingHelp: LocalizedStringKey {
        """
        Silence kept after each phrase, so word endings are not clipped when \
        silence is removed.
        """
    }
    static var segmentation: LocalizedStringKey { "Segmentation" }
    static var maximumSegmentLength: LocalizedStringKey { "Maximum segment length" }
    static var maximumSegmentHelp: LocalizedStringKey {
        """
        The longest stretch of audio transcribed as one unit. Shorter segments save \
        progress more often.
        """
    }
    static var segmentationFooter: LocalizedStringKey {
        """
        Segments are internal. They set how often work is saved, not how the \
        transcript reads.
        """
    }

    // MARK: - Settings: transcription

    static var settingsTranscription: LocalizedStringKey { "Transcription" }
    static var language: LocalizedStringKey { "Language" }
    static var languageHelp: LocalizedStringKey {
        """
        The language spoken in the recording. Getting this wrong costs accuracy \
        more than any other setting.
        """
    }
    static var verbatimOnlyNotice: LocalizedStringKey {
        """
        Verbatim only in this language. Clean and Polished need lexicons Vox \
        Scripta does not have yet.
        """
    }
    static var polishUnavailableNotice: LocalizedStringKey {
        """
        Polished is unavailable in Spanish. The check that catches a reversed \
        meaning does not work in Spanish, so the pass is withheld rather than run \
        unguarded.
        """
    }
    static var segmentsAtOnce: LocalizedStringKey { "Segments at once" }
    static var segmentsAtOnceHelp: LocalizedStringKey {
        """
        How many segments are transcribed in parallel. Four is fastest here; more \
        is not.
        """
    }
    static var concurrencyFooter: LocalizedStringKey {
        """
        Four is fastest on Apple silicon in our measurements. Changing this \
        re-transcribes, because results are only reproducible at a fixed setting.
        """
    }

    // MARK: - Settings: language stages

    static var settingsLanguage: LocalizedStringKey { "Language" }
    static var removeFillers: LocalizedStringKey { "Remove filler sounds" }
    static var removeFillersHelp: LocalizedStringKey {
        """
        Drop “um”, “uh”, “you know” and the like from the clean transcript. The \
        verbatim one keeps them.
        """
    }
    static var collapseStutters: LocalizedStringKey { "Collapse stutters" }
    static var collapseStuttersHelp: LocalizedStringKey {
        """
        Turn “the the the point” into “the point”. Only exact repeats are collapsed.
        """
    }
    static var cleanFooter: LocalizedStringKey {
        """
        Clean uses fixed rules. No language model is involved, and it can only \
        delete filler words — never rewrite what was said.
        """
    }
    static var createPolished: LocalizedStringKey { "Create a polished transcript" }
    static var createPolishedHelp: LocalizedStringKey {
        """
        Add a third transcript, rewritten sentence by sentence for readability. \
        This is the only stage that uses a language model, and it runs on this Mac.
        """
    }
    static var polishFooter: LocalizedStringKey {
        """
        Rewrites for readability one sentence at a time. Every sentence is checked \
        against the original; anything that changes a number, name, negation or \
        meaning is rejected and the clean text is kept.
        """
    }
    static var languageModel: LocalizedStringKey { "Language model" }
    static var languageModelHelp: LocalizedStringKey {
        """
        Which model does the polishing: Apple Intelligence, the model bundled with \
        the app, or whichever is available.
        """
    }
    static var willUse: LocalizedStringKey { "Will use" }
    static var willUseHelp: LocalizedStringKey {
        """
        The model a job would actually use right now, given what is installed on \
        this Mac.
        """
    }
    static var models: LocalizedStringKey { "Models" }
    static var appleIntelligence: LocalizedStringKey { "Apple Intelligence" }
    static var available: LocalizedStringKey { "Available" }
    static var unavailable: LocalizedStringKey { "Unavailable" }
    static var appleIntelligenceHelp: LocalizedStringKey {
        """
        Whether the system model is ready. It depends on your Mac and your Apple \
        Intelligence settings, not on Vox Scripta.
        """
    }
    static var bundledModel: LocalizedStringKey { "Bundled model" }
    static var notIncluded: LocalizedStringKey { "Not included in this build" }
    static var bundledModelHelp: LocalizedStringKey {
        """
        The model shipped inside the app. It works offline and needs no Apple \
        Intelligence.
        """
    }
    static var modelsFooter: LocalizedStringKey {
        """
        The bundled model ships inside the app, so polishing works even where Apple \
        Intelligence is unavailable. Nothing is ever downloaded — Vox Scripta has no \
        network access at all.
        """
    }

    // MARK: - Settings: storage and privacy

    static var settingsPrivacy: LocalizedStringKey { "Privacy" }
    static var storage: LocalizedStringKey { "Storage" }
    static var copyOriginal: LocalizedStringKey { "Copy the original into the project" }
    static var copyOriginalHelp: LocalizedStringKey {
        """
        Keep a second copy of the recording inside the project, so it survives the \
        original being moved. Your original is never touched either way.
        """
    }
    static var copyOriginalFooter: LocalizedStringKey {
        """
        Off by default, so a large recording is not duplicated. Vox Scripta never \
        modifies or moves the original either way.
        """
    }
    static var keepWorkingFiles: LocalizedStringKey { "Keep working files after transcribing" }
    static var keepWorkingFilesHelp: LocalizedStringKey {
        """
        Keep the decoded working audio so re-running with different settings is \
        fast. It costs disk space.
        """
    }
    static var keepWorkingFilesFooter: LocalizedStringKey {
        """
        Vox Scripta writes a working copy of the audio while it transcribes — about \
        1.4 GB for a six-hour recording. It is deleted when the job finishes; keep \
        it only if you want to re-run with different settings quickly.
        """
    }
    static var processedOnThisMac: LocalizedStringKey {
        "Audio is processed entirely on this Mac"
    }
    static var processedHelp: LocalizedStringKey {
        """
        The app is built without the network entitlement, so macOS itself prevents \
        it from connecting out.
        """
    }
    static var privacyFooter: LocalizedStringKey {
        """
        Vox Scripta ships without network access. It has no telemetry and no \
        accounts, and cannot upload anything.
        """
    }
    static var showProjectsFolder: LocalizedStringKey { "Show Projects Folder" }
    static var showProjectsFolderHelp: LocalizedStringKey {
        """
        Open the folder where Vox Scripta keeps its projects in Finder.
        """
    }
}
