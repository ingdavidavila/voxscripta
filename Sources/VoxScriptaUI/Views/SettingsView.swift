import SwiftUI
#if os(macOS)
import AppKit
#endif
import VoxScriptaCore
import VoxScriptaLanguage
import VoxScriptaPipeline

/// Advanced settings (§29), deliberately out of the main workflow.
public struct SettingsView: View {
    /// Public so the app shells — this package's executable and the iOS
    /// Xcode target — can construct it from outside the module.
    public init() {}

    @Environment(AppModel.self) private var model

    public var body: some View {
        @Bindable var model = model

        TabView {
            Form {
                Section(Strings.silenceDetection) {
                    LabeledContent(Strings.thresholdAboveNoise) {
                        Slider(value: $model.settings.silenceMarginDB, in: 3...20, step: 1) {
                            Text(Strings.thresholdAboveNoise)
                        }
                        .frame(width: 200)
                        Text("\(Int(model.settings.silenceMarginDB)) dB").monospacedDigit()
                    }
                    .help(Strings.thresholdHelp)
                    LabeledContent(Strings.shortestPause) {
                        Slider(value: $model.settings.minimumSilenceSeconds, in: 0.2...2, step: 0.1)
                            .frame(width: 200)
                        Text(String(format: "%.1f s", model.settings.minimumSilenceSeconds))
                            .monospacedDigit()
                    }
                    .help(Strings.shortestPauseHelp)
                    LabeledContent(Strings.paddingAfterSpeech) {
                        Slider(value: $model.settings.padTrailSeconds, in: 0...1, step: 0.05)
                            .frame(width: 200)
                        Text(String(format: "%.2f s", model.settings.padTrailSeconds))
                            .monospacedDigit()
                    }
                    .help(Strings.paddingHelp)
                }
                Section {
                    LabeledContent(Strings.maximumSegmentLength) {
                        Slider(value: $model.settings.maximumChunkSeconds, in: 60...600, step: 30)
                            .frame(width: 200)
                        Text("\(Int(model.settings.maximumChunkSeconds)) s").monospacedDigit()
                    }
                    .help(Strings.maximumSegmentHelp)
                } header: {
                    Text(Strings.segmentation)
                } footer: {
                    Text(Strings.segmentationFooter)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label(Strings.settingsAudio, systemImage: "waveform") }

            Form {
                Section(Strings.settingsTranscription) {
                    Toggle(Strings.detectLanguage, isOn: $model.settings.detectLanguage)
                        .help(Strings.detectLanguageHelp)
                    Picker(Strings.language, selection: $model.settings.locale) {
                        ForEach(model.availableLocales) { option in
                            Text(option.displayName).tag(option.identifier)
                        }
                    }
                    .help(Strings.languageHelp)
                    .task { await model.loadAvailableLocales() }

                    if model.settings.transcriptLanguage == nil {
                        // Says what will happen rather than hiding the locale.
                        // Transcription works; the text stages do not, because
                        // applying one language's filler list to another
                        // deletes real words.
                        Label(Strings.verbatimOnlyNotice, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if !model.settings.polishSupported {
                        Label(Strings.polishUnavailableNotice, systemImage: "exclamationmark.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if model.settings.transcriptLanguage
                                .map({ !SemanticSimilarity.catchesNegation(in: $0) }) == true {
                        // Running, but on one defence rather than two. Said
                        // plainly rather than left for the reader to discover.
                        Label(Strings.polishSingleDefenceNotice, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent(Strings.segmentsAtOnce) {
                        Stepper(value: $model.settings.concurrency, in: 1...8) {
                            Text("\(model.settings.concurrency)").monospacedDigit()
                        }
                    }
                    .help(Strings.segmentsAtOnceHelp)
                }
                Section {
                    Text(Strings.concurrencyFooter)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label(Strings.settingsTranscription, systemImage: "text.bubble") }

            Form {
                Section(Strings.clean) {
                    Toggle(Strings.removeFillers, isOn: $model.settings.removeFillers)
                        .help(Strings.removeFillersHelp)
                    Toggle(Strings.collapseStutters, isOn: $model.settings.collapseRepetitions)
                        .help(Strings.collapseStuttersHelp)
                    Toggle(Strings.dropLowConfidence, isOn: $model.settings.dropLowConfidence)
                        .help(Strings.dropLowConfidenceHelp)
                    Text(Strings.cleanFooter)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(Strings.polished) {
                    Toggle(Strings.createPolished, isOn: $model.settings.polishEnabled)
                        .disabled(!model.settings.polishSupported)
                        .help(Strings.createPolishedHelp)
                    Text(Strings.polishFooter)
                        .font(.caption).foregroundStyle(.secondary)

                    Picker(Strings.languageModel, selection: $model.settings.polishBackend) {
                        ForEach(PolishBackendPreference.allCases, id: \.self) { preference in
                            Text(preference.displayName).tag(preference)
                        }
                    }
                    .disabled(!model.settings.polishEnabled)
                    .help(Strings.languageModelHelp)

                    LabeledContent(Strings.willUse) {
                        Text(model.effectiveBackendDescription)
                            .foregroundStyle(.secondary)
                    }
                    .help(Strings.willUseHelp)
                }

                Section(Strings.models) {
                    LabeledContent(Strings.appleIntelligence) {
                        Label(model.systemModelAvailable ? Strings.available : Strings.unavailable,
                              systemImage: model.systemModelAvailable
                                  ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(model.systemModelAvailable ? .green : .secondary)
                            .labelStyle(.titleAndIcon)
                    }
                    .help(Strings.appleIntelligenceHelp)
                    LabeledContent(Strings.bundledModel) {
                        if let description = model.bundledModelDescription {
                            Text(description).foregroundStyle(.secondary)
                        } else {
                            Text(Strings.notIncluded).foregroundStyle(.secondary)
                        }
                    }
                    .help(Strings.bundledModelHelp)
                    Text(Strings.modelsFooter)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label(Strings.language, systemImage: "text.quote") }

            Form {
                Section(Strings.storage) {
                    Toggle(Strings.copyOriginal,
                           isOn: $model.settings.copyOriginalIntoProject)
                        .help(Strings.copyOriginalHelp)
                    Text(Strings.copyOriginalFooter)
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(Strings.keepWorkingFiles,
                           isOn: $model.settings.keepIntermediateFiles)
                        .help(Strings.keepWorkingFilesHelp)
                    Text(Strings.keepWorkingFilesFooter)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(Strings.settingsPrivacy) {
                    Label(Strings.processedOnThisMac, systemImage: "lock.fill")
                        .help(Strings.processedHelp)
                    Text(Strings.privacyFooter)
                        .font(.caption).foregroundStyle(.secondary)
                    #if os(macOS)
                    Button(Strings.showProjectsFolder) {
                        NSWorkspace.shared.open(AppModel.libraryDirectory)
                    }
                    .help(Strings.showProjectsFolderHelp)
                    #endif
                }
            }
            .formStyle(.grouped)
            .tabItem { Label(Strings.settingsPrivacy, systemImage: "lock") }
        }
        .padding(.top, 8)
    }
}
