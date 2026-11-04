import SwiftUI

/// The first thing a new user sees.
///
/// §25 asks for a workflow that is not overwhelming. This offers two actions
/// rather than one, because there are genuinely two ways in and assuming
/// either is wrong: the audio a person wants transcribed is either a file they
/// already have, or a sound happening in front of them right now.
///
/// What it no longer offers is an instruction to drag something. Dragging is a
/// Mac gesture that has no counterpart on a phone, and on the Mac it still
/// works — it is simply not the thing worth saying in the largest text on the
/// screen.
struct ImportView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(Strings.startHere)
                    .font(.title2.weight(.medium))
                Text(Strings.startSubtitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                Button {
                    model.beginRecording()
                } label: {
                    Label(Strings.record, systemImage: "mic.fill")
                        .frame(maxWidth: 220)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .help(Strings.recordHelp)

                Button {
                    model.presentImportPanel()
                } label: {
                    Label(Strings.chooseAudio, systemImage: "folder")
                        .frame(maxWidth: 220)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .help(Strings.chooseAudioHelp)
            }
            .disabled(model.isRunning)

            Divider().frame(width: 260).padding(.vertical, 4)

            VStack(spacing: 4) {
                Label(Strings.neverLeaves(), systemImage: "lock.fill")
                    .font(.callout)
                Text(Strings.originalUnmodified)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
