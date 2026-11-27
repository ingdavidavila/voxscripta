import SwiftUI
import VoxScriptaCore

/// What the pipeline noticed, above the transcript it noticed it about.
///
/// ## Why this exists at all
///
/// `SegmentWarning` has nine cases and every one of them was written into the
/// transcript JSON and shown to nobody — on the Mac, the iPhone, Android,
/// Windows and Linux alike. The channel was write-only from the day it was
/// built. The wrong-language warning made that unacceptable rather than untidy:
/// a VERBATIM transcript can read perfectly, in whole sentences, and be a
/// record of words nobody said, and the only thing standing between that and a
/// reader believing it is a line of text on this screen.
///
/// ## Why it is a banner and not a list
///
/// Because the warnings that matter most are about the whole recording and have
/// no position in it. `languageLooksWrong` and `fewWordsForSpeech` live on
/// ``Transcript/notes`` precisely because they belong to no segment. A reader
/// scrolling a long transcript would never reach a mark on a sentence; a line
/// above the text cannot be missed.
///
/// Per-segment marks are coming too — that is the agreed shape — but they wait
/// until the Flutter side can draw them, because its transcript screen is given
/// the plain-text export rather than segments. Shipping them here first would
/// put a mark on the Mac that four other platforms cannot show.
///
/// ## Why the ordering is not decided here
///
/// ``WarningSummary`` ranks and aggregates, in the engine, so this view and the
/// Flutter one cannot disagree about which warning is the headline or how many
/// there are. This file decides only how it looks and what it says in English.
struct WarningBanner: View {
    let warnings: [AggregatedWarning]
    @State private var isExpanded = false

    var body: some View {
        if let headline = warnings.first {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: icon(for: headline.warning))
                        .foregroundStyle(tint(for: headline.warning))
                        .accessibilityHidden(true)

                    Text(Self.sentence(for: headline))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if warnings.count > 1 {
                        Button {
                            isExpanded.toggle()
                        } label: {
                            Text(isExpanded
                                 ? Strings.warningsHide
                                 : Strings.warningsMore(warnings.count - 1))
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .help(Strings.warningsShowAll)
                    }
                }

                if isExpanded {
                    // The headline is already above, so only the rest.
                    ForEach(Array(warnings.dropFirst().enumerated()), id: \.offset) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: icon(for: entry.element.warning))
                                .foregroundStyle(tint(for: entry.element.warning))
                                .accessibilityHidden(true)
                            Text(Self.sentence(for: entry.element))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let seconds = entry.element.startSeconds {
                                Text(Self.timestamp(seconds))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint(for: headline.warning).opacity(0.12))
            .overlay(alignment: .top) { Divider() }
            .overlay(alignment: .bottom) { Divider() }
            .animation(.easeInOut(duration: 0.15), value: isExpanded)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Strings.warningsTitle)
        }
    }

    /// The sentence a reader sees, chosen by code.
    ///
    /// Switched on the case rather than read out of `values`: inside Swift the
    /// enum carries its own typed values, and going through the wire's string
    /// dictionary here would mean parsing numbers back out of a form built for
    /// Dart. `values` exists for the C ABI, not for this.
    @MainActor
    static func sentence(for entry: AggregatedWarning) -> LocalizedStringKey {
        switch entry.warning {
        case .languageLooksWrong(let transcribedAs, let detected):
            Strings.warnLanguageLooksWrong(languageName(detected),
                                           languageName(transcribedAs))
        case .fewWordsForSpeech(let words, let speechSeconds):
            Strings.warnFewWordsForSpeech(words, speechSeconds)
        case .transcriptionGap:
            Strings.warnTranscriptionGap
        case .cleanRemovedLowConfidence(let segments, _):
            Strings.warnRemovedLowConfidence(segments)
        case .cleanKeptAllBelowFloor:
            Strings.warnKeptAllBelowFloor
        case .polishFellBack:
            Strings.warnPolishFellBack(entry.count)
        case .mergeAmbiguity:
            Strings.warnMergeAmbiguity
        case .lowConfidence(let confidence):
            Strings.warnLowConfidence(entry.count, score(confidence))
        case .polishRetried:
            Strings.warnPolishRetried
        }
    }

    /// `es` becomes “Spanish”, in the reader's own language.
    ///
    /// The engine sends a language code because a code is what it knows; a
    /// reader should not be shown one. Falls back to the code itself rather than
    /// to nothing, so an unexpected language still produces a sentence that
    /// makes sense.
    static func languageName(_ code: String) -> String {
        let language = code.split(separator: "-").first.map(String.init) ?? code
        return Locale.current.localizedString(forLanguageCode: language)?
            .localizedCapitalized ?? code
    }

    /// A confidence score, formatted where formatting belongs.
    ///
    /// The engine sends the number unformatted on purpose: Spanish writes 0,42
    /// where English writes 0.42, and that is the interface's decision. This is
    /// the interface making it.
    static func score(_ confidence: Float) -> String {
        Double(confidence).formatted(.number.precision(.fractionLength(2)))
    }

    static func timestamp(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// Where "something is wrong with the text" ends and "for your
    /// information" begins.
    ///
    /// The boundary sits between `cleanKeptAllBelowFloor` and
    /// `polishFellBack`, and it is a real one rather than a round number:
    /// everything above it means words may be missing or may not be what was
    /// said, and everything below it means the text is present and intact and
    /// something merely happened on the way to it.
    ///
    /// It was `<= 2` first, which rendered `cleanRemovedLowConfidence` as a
    /// grey note. Seeing it on screen showed that for what it was: with CLEAN
    /// no longer offered, that warning is the *only* evidence that passages
    /// were dropped from the only edited version a reader has. A grey ⓘ is the
    /// wrong thing to say about missing words.
    private static let informationalFrom = 5

    private func isAboutTheText(_ warning: SegmentWarning) -> Bool {
        warning.severity < Self.informationalFrom
    }

    private func tint(for warning: SegmentWarning) -> Color {
        // Severity is the engine's, so the colour follows it rather than a
        // per-case opinion that could drift from the ordering.
        isAboutTheText(warning) ? .orange : .secondary
    }

    private func icon(for warning: SegmentWarning) -> String {
        isAboutTheText(warning) ? "exclamationmark.triangle.fill" : "info.circle"
    }
}
