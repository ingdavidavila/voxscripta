import Testing
import Foundation
@testable import VoxScriptaCore

/// The report a person sends, and what it must never carry.
///
/// This application has no telemetry and ships without a network entitlement.
/// The report exists so a failure can be reported anyway, by the person, with
/// their own mail app. That only works if they can read it first and find
/// nothing of theirs in it — so redaction is the feature, not a precaution
/// around it, and these are the tests that matter most in this file.
@Suite("Diagnostics report")
struct DiagnosticsReportTests {

    @Test("A path is reduced to its extension")
    func pathsAreReduced() {
        // The account name and the recording's title are the two most
        // identifying strings in the system, and both live in this one value.
        #expect(DiagnosticsReport.redact("/Users/marta/Interviews/Entrevista con Marta.wav")
                == "<path>.wav")
        #expect(DiagnosticsReport.redact("C:\\Users\\marta\\Board meeting.m4a")
                == "<path>.m4a")
        #expect(DiagnosticsReport.redact("/data/user/0/dev.voxscripta/files/models/ggml-base.bin")
                == "<path>.bin")
    }

    @Test("A path with no extension still loses its directories")
    func extensionlessPaths() {
        #expect(DiagnosticsReport.redact("/Users/marta/recordings") == "<path>")
    }

    @Test("A value that is not a path is left alone")
    func plainValuesSurvive() {
        // The diagnostic content has to survive or the report is useless.
        #expect(DiagnosticsReport.redact("es-ES") == "es-ES")
        #expect(DiagnosticsReport.redact("8192") == "8192")
        #expect(DiagnosticsReport.redact("device lost") == "device lost")
    }

    @Test("Anything holding a separator is treated as a path")
    func conservativeOnAmbiguity() {
        // A reason string that happens to contain a slash loses detail. That is
        // the right direction to be wrong in: a report that says too little
        // wastes a round trip, one that says too much cannot be withdrawn.
        #expect(DiagnosticsReport.redact("read/write failure") == "<path>")
    }

    @Test("Every value an error carries is reduced, not just the ones named path")
    func failureRedactsEveryValue() {
        let failure = DiagnosticsReport.Failure(
            .ioFailure(path: "/Users/marta/Projects/Marta.voxscripta", reason: "read-only"))
        #expect(failure.code == "ioFailure")
        #expect(failure.details["path"] == "<path>.voxscripta")
        #expect(failure.details["reason"] == "read-only")
    }

    @Test("The rendered report carries no transcript, path or account name")
    func renderedReportIsClean() {
        let report = DiagnosticsReport(
            engine: "whisper.cpp",
            modelIdentity: "ggml-base.bin",
            concurrency: 4,
            locale: "es-ES",
            jobState: "failed",
            chunksTotal: 12, chunksComplete: 9, chunksFailed: 3,
            failures: [
                DiagnosticsReport.Failure(.sourceChanged(path: "/Users/marta/Entrevista.wav")),
                DiagnosticsReport.Failure(.transcriptionFailed(chunk: ChunkID(), reason: "timeout"),
                                          chunk: 7),
            ])
        let text = report.formatted()

        #expect(!text.contains("marta"))
        #expect(!text.contains("Marta"))
        #expect(!text.contains("/Users"))
        #expect(!text.contains("Entrevista"))
        // And it still says enough to act on.
        #expect(text.contains("sourceChanged"))
        #expect(text.contains("whisper.cpp"))
        #expect(text.contains("9 of 12 complete, 3 failed"))
        #expect(text.contains("chunk 7"))
    }

    @Test("A report with nothing wrong says so rather than looking truncated")
    func cleanReportReadsAsClean() {
        let text = DiagnosticsReport(engine: "apple.speech-transcriber").formatted()
        #expect(text.contains("No failures recorded."))
    }

    @Test("The report tells the reader nothing is sent for them")
    func reportStatesItsOwnContract() {
        // The person is deciding whether to send this. The document should say
        // what it is, on the document, rather than in a dialog they have
        // already dismissed.
        let text = DiagnosticsReport().formatted()
        #expect(text.contains("no transcript text"))
        #expect(text.contains("you choose where this goes"))
    }
}
