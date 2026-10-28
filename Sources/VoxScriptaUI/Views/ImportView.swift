import SwiftUI

/// The first thing a new user sees.
///
/// §25 asks for a workflow that is not overwhelming, so this states the promise
/// and offers exactly one action. Every setting lives behind the Settings window.
struct ImportView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(Strings.dropRecording)
                    .font(.title2.weight(.medium))
                Text(Strings.dropSubtitle)
                    .foregroundStyle(.secondary)
            }

            Button(Strings.chooseAudio) { model.presentImportPanel() }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .help(Strings.chooseAudioHelp)

            Divider().frame(width: 260).padding(.vertical, 4)

            VStack(spacing: 4) {
                Label(Strings.neverLeaves, systemImage: "lock.fill")
                    .font(.callout)
                Text(Strings.originalUnmodified)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
