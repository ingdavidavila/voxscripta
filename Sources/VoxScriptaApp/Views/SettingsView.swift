import SwiftUI
import VoxScriptaCore
import VoxScriptaPipeline

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
                    .help("How far above the measured background noise a sound must be "
                          + "to count as speech. Raise it for a noisy recording.")
                    LabeledContent("Shortest pause") {
                        Slider(value: $model.settings.minimumSilenceSeconds, in: 0.2...2, step: 0.1)
                            .frame(width: 200)
                        Text(String(format: "%.1f s", model.settings.minimumSilenceSeconds))
                            .monospacedDigit()
                    }
                    .help("A quiet stretch shorter than this is treated as part of "
                          + "the speech, not as a pause.")
                    LabeledContent("Padding after speech") {
                        Slider(value: $model.settings.padTrailSeconds, in: 0...1, step: 0.05)
                            .frame(width: 200)
                        Text(String(format: "%.2f s", model.settings.padTrailSeconds))
                            .monospacedDigit()
                    }
                    .help("Silence kept after each phrase, so word endings are not "
                          + "clipped when silence is removed.")
                }
                Section {
                    LabeledContent("Maximum segment length") {
                        Slider(value: $model.settings.maximumChunkSeconds, in: 60...600, step: 30)
                            .frame(width: 200)
                        Text("\(Int(model.settings.maximumChunkSeconds)) s").monospacedDigit()
                    }
                    .help("The longest stretch of audio transcribed as one unit. "
                          + "Shorter segments save progress more often.")
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
                        ForEach(model.availableLocales) { option in
                            Text(option.displayName).tag(option.identifier)
                        }
                    }
                    .help("The language spoken in the recording. Getting this wrong "
                          + "costs accuracy more than any other setting.")
                    .task { await model.loadAvailableLocales() }

                    if model.settings.transcriptLanguage == nil {
                        // Says what will happen rather than hiding the locale.
                        // Transcription works; the text stages do not, because
                        // applying one language's filler list to another
                        // deletes real words.
                        Label("Verbatim only in this language. Clean and Polished "
                              + "need lexicons VoxScripta does not have yet.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if model.settings.transcriptLanguage == .spanish {
                        Label("Polished is unavailable in Spanish. The check that "
                              + "catches a reversed meaning does not work in "
                              + "Spanish, so the pass is withheld rather than run "
                              + "unguarded.",
                              systemImage: "exclamationmark.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Segments at once") {
                        Stepper(value: $model.settings.concurrency, in: 1...8) {
                            Text("\(model.settings.concurrency)").monospacedDigit()
                        }
                    }
                    .help("How many segments are transcribed in parallel. "
                          + "Four is fastest here; more is not.")
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
                        .help("Drop “um”, “uh”, “you know” and the like from the "
                              + "clean transcript. The verbatim one keeps them.")
                    Toggle("Collapse stutters", isOn: $model.settings.collapseRepetitions)
                        .help("Turn “the the the point” into “the point”. "
                              + "Only exact repeats are collapsed.")
                    Text("Clean uses fixed rules. No language model is involved, and it can only delete filler words — never rewrite what was said.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Polished") {
                    Toggle("Create a polished transcript", isOn: $model.settings.polishEnabled)
                        .disabled(!model.settings.polishSupported)
                        .help("Add a third transcript, rewritten sentence by sentence "
                              + "for readability. This is the only stage that uses a "
                              + "language model, and it runs on this Mac.")
                    Text("Rewrites for readability one sentence at a time. Every sentence is checked against the original; anything that changes a number, name, negation or meaning is rejected and the clean text is kept.")
                        .font(.caption).foregroundStyle(.secondary)

                    Picker("Language model", selection: $model.settings.polishBackend) {
                        ForEach(PolishBackendPreference.allCases, id: \.self) { preference in
                            Text(preference.displayName).tag(preference)
                        }
                    }
                    .disabled(!model.settings.polishEnabled)
                    .help("Which model does the polishing: Apple Intelligence, the "
                          + "model bundled with the app, or whichever is available.")

                    LabeledContent("Will use") {
                        Text(model.effectiveBackendDescription)
                            .foregroundStyle(.secondary)
                    }
                    .help("The model a job would actually use right now, "
                          + "given what is installed on this Mac.")
                }

                Section("Models") {
                    LabeledContent("Apple Intelligence") {
                        Label(model.systemModelAvailable ? "Available" : "Unavailable",
                              systemImage: model.systemModelAvailable
                                  ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(model.systemModelAvailable ? .green : .secondary)
                            .labelStyle(.titleAndIcon)
                    }
                    .help("Whether the system model is ready. It depends on your Mac "
                          + "and your Apple Intelligence settings, not on Vox Scripta.")
                    LabeledContent("Bundled model") {
                        Text(model.bundledModelDescription ?? "Not included in this build")
                            .foregroundStyle(.secondary)
                    }
                    .help("The model shipped inside the app. It works offline and "
                          + "needs no Apple Intelligence.")
                    Text("The bundled model ships inside the app, so polishing works even where Apple Intelligence is unavailable. Nothing is ever downloaded — Vox Scripta has no network access at all.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Language", systemImage: "text.quote") }

            Form {
                Section("Storage") {
                    Toggle("Copy the original into the project",
                           isOn: $model.settings.copyOriginalIntoProject)
                        .help("Keep a second copy of the recording inside the project, "
                              + "so it survives the original being moved. "
                              + "Your original is never touched either way.")
                    Text("Off by default, so a large recording is not duplicated. Vox Scripta never modifies or moves the original either way.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Keep working files after transcribing",
                           isOn: $model.settings.keepIntermediateFiles)
                        .help("Keep the decoded working audio so re-running with "
                              + "different settings is fast. It costs disk space.")
                    Text("Vox Scripta writes a working copy of the audio while it transcribes — about 1.4 GB for a six-hour recording. It is deleted when the job finishes; keep it only if you want to re-run with different settings quickly.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Privacy") {
                    Label("Audio is processed entirely on this Mac", systemImage: "lock.fill")
                        .help("The app is built without the network entitlement, "
                              + "so macOS itself prevents it from connecting out.")
                    Text("Vox Scripta ships without network access. It has no telemetry and no accounts, and cannot upload anything.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Show Projects Folder") {
                        NSWorkspace.shared.open(AppModel.libraryDirectory)
                    }
                    .help("Open the folder where Vox Scripta keeps its projects in Finder.")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Privacy", systemImage: "lock") }
        }
        .padding(.top, 8)
    }
}
