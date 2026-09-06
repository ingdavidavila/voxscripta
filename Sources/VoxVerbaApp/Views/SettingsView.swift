import SwiftUI
import VoxVerbaCore
import VoxVerbaPipeline

/// Advanced settings (§29), deliberately out of the main workflow.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        TabView {
            Form {
                Section("Silence detection") {
                    LabeledContent("Threshold above noise floor") {
                        Slider(value: $model.settings.silenceMarginDB, in: 3...20, step: 1) {
                            Text("Threshold")
                        }
                        .frame(width: 200)
                        Text("\(Int(model.settings.silenceMarginDB)) dB").monospacedDigit()
                    }
                    LabeledContent("Shortest pause") {
                        Slider(value: $model.settings.minimumSilenceSeconds, in: 0.2...2, step: 0.1)
                            .frame(width: 200)
                        Text(String(format: "%.1f s", model.settings.minimumSilenceSeconds))
                            .monospacedDigit()
                    }
                    LabeledContent("Padding after speech") {
                        Slider(value: $model.settings.padTrailSeconds, in: 0...1, step: 0.05)
                            .frame(width: 200)
                        Text(String(format: "%.2f s", model.settings.padTrailSeconds))
                            .monospacedDigit()
                    }
                }
                Section {
                    LabeledContent("Maximum segment length") {
                        Slider(value: $model.settings.maximumChunkSeconds, in: 60...600, step: 30)
                            .frame(width: 200)
                        Text("\(Int(model.settings.maximumChunkSeconds)) s").monospacedDigit()
                    }
                } header: {
                    Text("Segmentation")
                } footer: {
                    Text("Segments are internal. They set how often work is saved, not how the transcript reads.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Audio", systemImage: "waveform") }

            Form {
                Section("Transcription") {
                    Picker("Language", selection: $model.settings.locale) {
                        Text("English (US)").tag("en-US")
                        Text("English (UK)").tag("en-GB")
                        Text("English (Australia)").tag("en-AU")
                    }
                    LabeledContent("Segments at once") {
                        Stepper(value: $model.settings.concurrency, in: 1...8) {
                            Text("\(model.settings.concurrency)").monospacedDigit()
                        }
                    }
                }
                Section {
                    Text("Four is fastest on Apple silicon in our measurements. "
                         + "Changing this re-transcribes, because results are only "
                         + "reproducible at a fixed setting.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Transcription", systemImage: "text.bubble") }

            Form {
                Section("Clean") {
                    Toggle("Remove filler sounds", isOn: $model.settings.removeFillers)
                    Toggle("Collapse stutters", isOn: $model.settings.collapseRepetitions)
                    Text("Clean uses fixed rules. No language model is involved, and it can only delete filler words — never rewrite what was said.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Polished") {
                    Toggle("Create a polished transcript", isOn: $model.settings.polishEnabled)
                    Text("Rewrites for readability one sentence at a time. Every sentence is checked against the original; anything that changes a number, name, negation or meaning is rejected and the clean text is kept.")
                        .font(.caption).foregroundStyle(.secondary)

                    Picker("Language model", selection: $model.settings.polishBackend) {
                        ForEach(PolishBackendPreference.allCases, id: \.self) { preference in
                            Text(preference.displayName).tag(preference)
                        }
                    }
                    .disabled(!model.settings.polishEnabled)

                    LabeledContent("Will use") {
                        Text(model.effectiveBackendDescription)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Models") {
                    LabeledContent("Apple Intelligence") {
                        Label(model.systemModelAvailable ? "Available" : "Unavailable",
                              systemImage: model.systemModelAvailable
                                  ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(model.systemModelAvailable ? .green : .secondary)
                            .labelStyle(.titleAndIcon)
                    }
                    LabeledContent("Bundled model") {
                        Text(model.bundledModelDescription ?? "Not included in this build")
                            .foregroundStyle(.secondary)
                    }
                    Text("The bundled model ships inside the app, so polishing works even where Apple Intelligence is unavailable. Nothing is ever downloaded — VoxVerba has no network access at all.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Language", systemImage: "text.quote") }

            Form {
                Section("Storage") {
                    Toggle("Copy the original into the project",
                           isOn: $model.settings.copyOriginalIntoProject)
                    Text("Off by default, so a large recording is not duplicated. VoxVerba never modifies or moves the original either way.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Keep working files after transcribing",
                           isOn: $model.settings.keepIntermediateFiles)
                    Text("VoxVerba writes a working copy of the audio while it transcribes — about 1.4 GB for a six-hour recording. It is deleted when the job finishes; keep it only if you want to re-run with different settings quickly.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Privacy") {
                    Label("Audio is processed entirely on this Mac", systemImage: "lock.fill")
                    Text("VoxVerba ships without network access. It has no telemetry and no accounts, and cannot upload anything.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Show Projects Folder") {
                        NSWorkspace.shared.open(AppModel.libraryDirectory)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Privacy", systemImage: "lock") }
        }
        .padding(.top, 8)
    }
}
