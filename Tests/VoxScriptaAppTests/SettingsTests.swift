import Testing
import Foundation
import VoxScriptaCore
@testable import VoxScriptaApp

@Suite("App settings")
struct AppSettingsTests {

    @Test("Defaults match the engine's own defaults")
    func defaultsAgree() {
        // Settings are a presentation of pipeline parameters. If the two drift,
        // the UI silently shows a value the pipeline is not using.
        let settings = AppSettings()
        #expect(settings.silenceParameters.marginDB == SilenceParameters.default.marginDB)
        #expect(settings.chunkParameters.maxDuration == ChunkParameters.default.maxDuration)
        #expect(settings.concurrency == 4)
    }

    @Test("Adjusting a slider produces the parameters the pipeline expects")
    func mapsToParameters() {
        var settings = AppSettings()
        settings.silenceMarginDB = 12
        settings.minimumSilenceSeconds = 0.8
        settings.maximumChunkSeconds = 120

        #expect(settings.silenceParameters.marginDB == 12)
        #expect(settings.silenceParameters.minSilenceDuration == .seconds(0.8))
        #expect(settings.chunkParameters.maxDuration == .seconds(120))
        // Target and minimum track the maximum, so the planner stays coherent.
        #expect(settings.chunkParameters.targetDuration < settings.chunkParameters.maxDuration)
        #expect(settings.chunkParameters.minDuration < settings.chunkParameters.targetDuration)
    }

    @Test("Turning off cleaning options reaches the clean processor")
    func cleanToggles() {
        var settings = AppSettings()
        settings.removeFillers = false
        settings.collapseRepetitions = false
        #expect(!settings.cleanParameters.removeFillers)
        #expect(!settings.cleanParameters.collapseRepetitions)
    }

    @Test("Settings round-trip through JSON")
    func codable() throws {
        var settings = AppSettings()
        settings.locale = "en-GB"
        settings.polishEnabled = false
        settings.copyOriginalIntoProject = true

        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(back == settings)
        #expect(back.locale == "en-GB")
        #expect(!back.polishEnabled)
    }

    @Test("Copying the original is off by default")
    func referenceByDefault() {
        // Silently duplicating a multi-gigabyte recording is a surprise.
        #expect(!AppSettings().copyOriginalIntoProject)
    }
}
