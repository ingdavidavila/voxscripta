import SwiftUI
import AppKit
import VoxVerbaCore
import VoxVerbaLanguage
import VoxVerbaExport

/// The three outputs, and the evidence behind them.
struct TranscriptWorkspace: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            picker
            Divider()

            HSplitView {
                TranscriptTextView(text: model.currentTranscript?.plainText() ?? "")
                    .frame(minWidth: 380)

                if model.showsValidationDetail {
                    ValidationPanel()
                        .frame(minWidth: 280, idealWidth: 340, maxWidth: 460)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                if !model.polishReport.isEmpty || model.polishSkipReason != nil {
                    Toggle(isOn: $model.showsValidationDetail) {
                        Label("Review", systemImage: "checkmark.shield")
                    }
                    .help("Show what the polish pass changed, and what it refused to change.")
                }

                Button { model.copyTranscript() } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(model.currentTranscript == nil)
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help("Copy the whole \(model.selectedVariant.displayName.lowercased()) "
                      + "transcript to the clipboard. (⇧⌘C)")

                // A plain click saves the transcript; the arrow opens the other
                // formats. Downloading should not require finding a submenu first.
                Menu {
                    Section("Save As") {
                        ForEach(model.exportableFormats, id: \.self) { format in
                            Button(format.displayName) { model.export(format) }
                                .help(format.explanation)
                        }
                    }
                    Divider()
                    Toggle("Include timestamps", isOn: $model.exportIncludesTimestamps)
                        .help("Write each segment's start time alongside its text. "
                              + "Subtitle formats always carry timings.")
                    Divider()
                    Button("Save Every Variant…") { model.exportAll() }
                        .help("Write the verbatim, clean and polished transcripts "
                              + "to one folder.")
                    Button("Audio with Silence Removed…") {
                        model.renderSilenceRemovedAudio()
                    }
                    .disabled(model.silenceMap == nil || model.isRendering)
                    .help("Render a new audio file with the silences taken out. "
                          + "Your original recording is left untouched.")
                } label: {
                    Label("Download", systemImage: "square.and.arrow.down")
                } primaryAction: {
                    model.export(model.defaultExportFormat)
                }
                .menuIndicator(.visible)
                .disabled(model.currentTranscript == nil)
                .help("Save this transcript as "
                      + "\(model.defaultExportFormat.displayName). "
                      + "Use the arrow for other formats.")
            }
        }
    }

    private var picker: some View {
        @Bindable var model = model

        return HStack {
            Picker("", selection: $model.selectedVariant) {
                ForEach(model.availableVariants, id: \.self) { variant in
                    Text(variant.displayName)
                        .help(variant.explanation)
                        .tag(variant)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 340)
            .help(model.selectedVariant.explanation)

            Spacer()

            if let note = model.copyConfirmation {
                Label(note, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                    .padding(.trailing, 4)
            }

            if let transcript = model.currentTranscript {
                Text("\(transcript.wordCount) words · \(transcript.segments.count) segments")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(12)
        .animation(.easeInOut(duration: 0.15), value: model.copyConfirmation)
    }
}

extension ExportFormat {
    var displayName: String {
        switch self {
        case .plainText: "Plain Text (.txt)"
        case .markdown: "Markdown (.md)"
        case .docx: "Word (.docx)"
        case .subRip: "Subtitles (.srt)"
        case .webVTT: "Web Captions (.vtt)"
        }
    }

    var explanation: String {
        switch self {
        case .plainText: "Just the words, in a file any editor can open."
        case .markdown: "Words with light formatting, for notes and documentation."
        case .docx: "A Word document, for sharing and further editing."
        case .subRip: "Timed subtitles, the format most video editors expect."
        case .webVTT: "Timed captions for the web."
        }
    }
}

extension TranscriptVariant {
    var displayName: String {
        switch self {
        case .verbatim: "Verbatim"
        case .clean: "Clean"
        case .polished: "Polished"
        }
    }

    var explanation: String {
        switch self {
        case .verbatim: "Exactly what was said, including hesitations."
        case .clean: "Tidied by fixed rules. No language model was involved."
        case .polished: "Rewritten for readability, checked against the original."
        }
    }
}

/// Shows what polish changed and what it was refused.
///
/// §14 asks that suspicious transformations be detectable. Making them visible is
/// the other half of that: a validator that silently keeps the clean text leaves
/// the reader no way to know a sentence was contested.
struct ValidationPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let reason = model.polishSkipReason {
                    Label("Polish did not run", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    summary
                    if model.flaggedSentences.isEmpty {
                        Label("Every sentence passed on the first attempt.",
                              systemImage: "checkmark.seal")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(model.flaggedSentences.enumerated()), id: \.offset) { _, item in
                            FlaggedSentenceRow(sentence: item)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background.secondary)
    }

    private var summary: some View {
        let report = model.polishReport
        let accepted = report.count { $0.disposition == .accepted }
        let retried = report.count { $0.disposition == .acceptedAfterRetry }
        let kept = report.count {
            $0.disposition == .fellBackToClean || $0.disposition == .modelFailed
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Polish review").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow { Text("Accepted"); Text("\(accepted)").monospacedDigit() }
                GridRow { Text("Accepted after retry"); Text("\(retried)").monospacedDigit() }
                GridRow { Text("Kept the clean text"); Text("\(kept)").monospacedDigit() }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}

struct FlaggedSentenceRow: View {
    let sentence: PolishedSentence

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)

            Text(sentence.original)
                .font(.callout)
                .textSelection(.enabled)

            ForEach(Array(sentence.report.failureReasons.enumerated()), id: \.offset) { _, reason in
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: 8))
    }

    private var title: String {
        switch sentence.disposition {
        case .accepted: "Accepted"
        case .acceptedAfterRetry: "Accepted after retry"
        case .fellBackToClean: "Kept the clean text"
        case .modelFailed: "The model could not run"
        }
    }

    private var icon: String {
        switch sentence.disposition {
        case .accepted, .acceptedAfterRetry: "checkmark.circle"
        case .fellBackToClean, .modelFailed: "shield.lefthalf.filled"
        }
    }

    private var tint: Color {
        switch sentence.disposition {
        case .accepted, .acceptedAfterRetry: .secondary
        case .fellBackToClean, .modelFailed: .orange
        }
    }
}

/// An `NSTextView` behind a SwiftUI face.
///
/// SwiftUI's own text views do not scroll a six-hour transcript acceptably — on
/// the order of 60,000 words across thousands of segments — and no configuration
/// fixes it. TextKit 2 lays out only the visible viewport and brings real find,
/// selection and accessibility with it.
struct TranscriptTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 20, height: 20)
        textView.font = .systemFont(ofSize: 14)
        textView.backgroundColor = .textBackgroundColor
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text else { return }
        textView.string = text
        textView.scroll(.zero)
    }
}
