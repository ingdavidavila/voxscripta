import SwiftUI
import VoxScriptaCore
import VoxScriptaDSP

/// What the user watches while a job runs.
///
/// §18 asks that this never look frozen. The waveform appears as soon as analysis
/// finishes — well before transcription starts — so there is something real on
/// screen during the longest phase, and the phase list shows where the work is
/// rather than only how far along it is.
struct ProcessingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            if let peaks = model.peaks {
                WaveformView(peaks: peaks, speechRegions: model.silenceMap?.speechRegions ?? [])
                    .frame(height: 96)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.4))
                    .frame(height: 96)
                    .overlay { Text(Strings.readingAudio).foregroundStyle(.secondary) }
            }

            PhaseList(current: model.phase)

            Spacer()
        }
        .padding(28)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.openProject?.manifest.source.displayName ?? "Processing")
                .font(.title2.weight(.medium))
                .lineLimit(1)

            ProgressView(value: model.progress) {
                Text(model.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } currentValueLabel: {
                Text("\(Int(model.progress * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .progressViewStyle(.linear)

            if let map = model.silenceMap {
                Text("\(map.speechRegions.count) speech regions · "
                     + "\(Int(map.speechFraction * 100))% of the recording is speech")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The pipeline's phases, with the current one highlighted.
struct PhaseList: View {
    let current: JobState

    private static let labels: [(JobState, String)] = [
        (.analyzing, "Analyze audio"),
        (.silenceProcessing, "Detect silence"),
        (.chunking, "Plan segments"),
        (.transcribing, "Transcribe"),
        (.merging, "Assemble transcript"),
        (.cleaning, "Clean"),
        (.polishing, "Polish"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.labels, id: \.0) { state, label in
                HStack(spacing: 10) {
                    icon(for: state)
                        .frame(width: 16)
                    Text(label)
                        .foregroundStyle(state == current ? .primary : .secondary)
                        .fontWeight(state == current ? .medium : .regular)
                }
                .font(.callout)
            }
        }
    }

    @ViewBuilder
    private func icon(for state: JobState) -> some View {
        if current == .complete || state.nominalProgress < current.nominalProgress {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
        } else if state == current {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: "circle").foregroundStyle(.quaternary)
        }
    }
}

/// Draws the waveform with detected speech highlighted.
///
/// Canvas rather than a stack of shapes: a few thousand buckets as individual
/// views would cost more in layout than the whole analysis pass did.
struct WaveformView: View {
    let peaks: WaveformPeaks
    let speechRegions: [SpeechRegion]

    var body: some View {
        Canvas { context, size in
            let midline = size.height / 2
            let total = peaks.duration.seconds
            guard total > 0, peaks.count > 0 else { return }

            // Speech regions behind the trace, so quiet stretches read as gaps.
            for region in speechRegions {
                let x0 = region.range.start.seconds / total * size.width
                let x1 = region.range.end.seconds / total * size.width
                context.fill(
                    Path(CGRect(x: x0, y: 0, width: Swift.max(x1 - x0, 1), height: size.height)),
                    with: .color(.accentColor.opacity(0.16)))
            }

            var path = Path()
            let step = size.width / CGFloat(peaks.count)
            for index in 0..<peaks.count {
                let x = CGFloat(index) * step
                let high = midline - CGFloat(peaks.maxima[index]) * midline
                let low = midline - CGFloat(peaks.minima[index]) * midline
                path.move(to: CGPoint(x: x, y: high))
                path.addLine(to: CGPoint(x: x, y: Swift.max(low, high + 0.5)))
            }
            context.stroke(path, with: .color(.primary.opacity(0.55)), lineWidth: Swift.max(step, 0.6))
        }
        .accessibilityLabel("Waveform with \(speechRegions.count) detected speech regions")
    }
}
