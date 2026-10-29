import SwiftUI

/// What is on screen while the microphone is open.
///
/// Three things, in order of how much they matter: how long this has been
/// running, whether the microphone is hearing anything, and how to stop. The
/// meter is not decoration — a recording that captured silence looks exactly
/// like a successful one until the transcript comes back empty, and this is
/// the only moment at which that is cheap to notice.
struct RecordingView: View {
    @Environment(AppModel.self) private var model
    @State private var isConfirmingDiscard = false

    private var recorder: AudioRecorder { model.recorder }

    var body: some View {
        VStack(spacing: 28) {
            Label {
                Text(status)
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(recorder.state == .recording
                                     ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
            .font(.headline)
            .symbolEffect(.pulse, isActive: recorder.state == .recording)

            Text(recorder.state == .starting ? "—" : Self.clock(recorder.elapsed))
                .font(.system(size: 54, weight: .light, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .accessibilityLabel(Text(Self.clock(recorder.elapsed)))

            LevelMeter(levels: recorder.levels, isLive: recorder.state == .recording)
                .frame(height: 56)
                .frame(maxWidth: 420)
                .accessibilityHidden(true)

            HStack(spacing: 14) {
                Button(role: .destructive) {
                    if recorder.state == .starting {
                        model.discardRecording()
                    } else {
                        isConfirmingDiscard = true
                    }
                } label: {
                    Label(recorder.state == .starting ? Strings.cancel
                                                      : Strings.discardRecording,
                          systemImage: recorder.state == .starting ? "xmark" : "trash")
                }
                .help(Strings.discardRecordingHelp)

                // Both need a microphone that is actually open. Disabled
                // one by one rather than on the row, because `.disabled`
                // inherits downwards and would take Cancel with it — and
                // Cancel is the only way out of a route that never starts.
                if recorder.state == .paused {
                    Button { recorder.resume() } label: {
                        Label(Strings.resumeRecording, systemImage: "mic.fill")
                    }
                    .help(Strings.resumeRecordingHelp)
                } else {
                    Button { recorder.pause() } label: {
                        Label(Strings.pauseRecording, systemImage: "pause.fill")
                    }
                    .disabled(recorder.state == .starting)
                    .help(Strings.pauseRecordingHelp)
                }

                Button { model.finishRecording() } label: {
                    Label(Strings.finishRecording, systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(recorder.state == .starting)
                .help(Strings.finishRecordingHelp)
            }
            .controlSize(.large)

            Label(Strings.neverLeaves(), systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Discarding deletes audio, which is the one thing this app otherwise
        // never does, so it is the one thing that asks first.
        .confirmationDialog(Strings.discardRecordingTitle,
                            isPresented: $isConfirmingDiscard,
                            titleVisibility: .visible) {
            Button(Strings.discardRecording, role: .destructive) { model.discardRecording() }
                .help(Strings.discardRecordingHelp)
            Button(Strings.keepRecording, role: .cancel) {}
                .help(Strings.resumeRecordingHelp)
        } message: {
            Text(Strings.discardRecordingMessage)
        }
        .interactiveDismissDisabled()
    }

    private var status: LocalizedStringKey {
        switch recorder.state {
        case .starting: Strings.recordingStarting
        case .paused: Strings.recordingPaused
        default: Strings.recordingInProgress
        }
    }

    private var icon: String {
        switch recorder.state {
        case .starting: "mic.badge.plus"
        case .paused: "pause.circle.fill"
        default: "record.circle"
        }
    }

    /// `h:mm:ss` once there is an hour, `m:ss` before that.
    ///
    /// Formatted here rather than with a date style because this is an
    /// elapsed duration, and the hour place should appear when it is reached
    /// instead of sitting at zero for the first hour of every recording.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

/// A row of bars showing recent input level.
///
/// Drawn from the recorder's own history array, so it scrolls leftwards as
/// samples arrive without this view keeping any state of its own.
struct LevelMeter: View {
    let levels: [Double]
    let isLive: Bool

    private static let barWidth: CGFloat = 4
    private static let spacing: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            let capacity = Swift.max(1, Int(geometry.size.width
                                            / (Self.barWidth + Self.spacing)))
            let shown = Array(levels.suffix(capacity))
            // Padded at the front so the bars fill from the right as the
            // recording starts, rather than stretching to fit two samples.
            let padding = Swift.max(0, capacity - shown.count)

            HStack(alignment: .center, spacing: Self.spacing) {
                ForEach(0..<padding, id: \.self) { _ in
                    bar(level: 0, height: geometry.size.height)
                }
                ForEach(Array(shown.enumerated()), id: \.offset) { _, level in
                    bar(level: level, height: geometry.size.height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
    }

    private func bar(level: Double, height: CGFloat) -> some View {
        // A floor of two points, so an idle meter is a visible line rather
        // than nothing at all — "no signal" and "not running" should not look
        // the same.
        Capsule()
            .fill(isLive ? Color.accentColor : Color.secondary)
            .opacity(level > 0.02 ? 1 : 0.35)
            .frame(width: Self.barWidth,
                   height: Swift.max(2, height * CGFloat(level)))
    }
}
