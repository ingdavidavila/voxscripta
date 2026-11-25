import Testing
import Foundation
@testable import VoxScriptaCore

/// The machine-readable half of an error.
///
/// Worth pinning because these codes leave the process: an interface maps each
/// one to a sentence in the reader's language, so renaming a code does not
/// break a build anywhere — it silently drops that error back to English on
/// every platform that was translating it.
@Suite("Error codes")
struct ErrorCodeTests {

    /// One of every case. Written out rather than derived, so that adding a
    /// case to the enum and forgetting it here is visible as a gap in this
    /// list rather than as nothing at all.
    static let everyCase: [VoxScriptaError] = [
        .sourceUnavailable(path: "/a.wav"),
        .sourceChanged(path: "/a.wav"),
        .unsupportedFormat(description: "ape"),
        .noAudioTrack(path: "/a.mp4"),
        .unsupportedContainer(fileExtension: "rm"),
        .decodingFailed(reason: "truncated"),
        .noWordsRecognized(locale: "es-ES"),
        .microphoneDenied,
        .recordingFailed(reason: "device lost"),
        .analysisFailed(stage: "vad", reason: "nan"),
        .noSpeechDetected,
        .engineUnavailable(.whisper, reason: "no model"),
        .localeUnsupported(.appleSpeech, locale: "cy"),
        .transcriptionFailed(chunk: ChunkID(), reason: "timeout"),
        .modelAssetMissing(description: "ggml-base.bin"),
        .modelUnavailable(ModelID(backend: "llama", identifier: "polish-0.5b"), reason: "absent"),
        .contextWindowExceeded(tokens: 9000, limit: 8192),
        .validationRejected(reasons: ["drifted", "too short"]),
        .projectCorrupt(reason: "bad json"),
        .schemaTooNew(found: 9, supported: 7),
        .insufficientDiskSpace(needed: 2048, available: 10),
        .ioFailure(path: "/x", reason: "read-only"),
        .notEntitled(reason: "trial ended"),
        .cancelled,
        .notImplemented("phase 4"),
    ]

    @Test("Every case has a code, and no two share one")
    func codesAreUniqueAndPresent() {
        let codes = Self.everyCase.map(\.code)
        #expect(codes.allSatisfy { !$0.isEmpty })
        #expect(Set(codes).count == codes.count)
    }

    @Test("A code names its case, so a reader can map it without the source")
    func codesAreStable() {
        // Spot-checked rather than exhaustive: the point is the naming rule,
        // and an exhaustive copy of the switch would only test that the file
        // equals itself.
        #expect(VoxScriptaError.microphoneDenied.code == "microphoneDenied")
        #expect(VoxScriptaError.cancelled.code == "cancelled")
        #expect(VoxScriptaError.sourceChanged(path: "/a").code == "sourceChanged")
        #expect(VoxScriptaError.notEntitled(reason: "x").code == "notEntitled")
    }

    @Test("Details carry the values the sentence interpolates")
    func detailsCarryTheValues() {
        #expect(VoxScriptaError.sourceChanged(path: "/a.wav").details == ["path": "/a.wav"])
        #expect(VoxScriptaError.ioFailure(path: "/x", reason: "read-only").details
                == ["path": "/x", "reason": "read-only"])
        #expect(VoxScriptaError.microphoneDenied.details.isEmpty)
    }

    @Test("Numbers stay unformatted, because the reader's locale is not ours")
    func numbersAreNotFormatted() {
        // errorDescription runs these through formatted(), which puts a
        // separator in by this process's locale. An interface formatting
        // "1.000" again would produce nonsense, so details keep the digits.
        let error = VoxScriptaError.contextWindowExceeded(tokens: 9000, limit: 8192)
        #expect(error.details["tokens"] == "9000")
        #expect(error.details["limit"] == "8192")
    }

    @Test("A case with values never reports an empty detail set")
    func casesWithValuesCarryThem() {
        for error in Self.everyCase {
            let hasValues: Bool
            switch error {
            case .microphoneDenied, .noSpeechDetected, .cancelled: hasValues = false
            default: hasValues = true
            }
            #expect(error.details.isEmpty != hasValues,
                    "\(error.code) disagrees about whether it carries values")
        }
    }
}

/// The password checklist, as something an interface can translate.
///
/// Same problem as the error taxonomy: the engine renders English off Apple
/// and cannot do otherwise, so a localized interface has to rebuild the
/// sentence from the parts.
@Suite("Password rule details")
struct PasswordRuleDetailTests {

    @Test("The length rule carries its number, so nobody has to hardcode it")
    func lengthCarriesItsMinimum() throws {
        // An interface keying off the id could otherwise only say
        // "Al menos 8 caracteres" by writing 8 into Dart, where it would
        // disagree with minimumLength the first time it moved — silently,
        // because nothing compares the two.
        let rules = PasswordPolicy.evaluate("short")
        let length = try #require(rules.first { $0.id == "length" })
        #expect(length.details["minimum"] == String(PasswordPolicy.minimumLength))
    }

    @Test("Rules without values say so rather than inventing one")
    func valuelessRulesAreEmpty() {
        let rules = PasswordPolicy.evaluate("short")
        for id in ["uppercase", "number", "special"] {
            #expect(rules.first { $0.id == id }?.details.isEmpty == true)
        }
    }

    @Test("Every rule has an id an interface can key off")
    func everyRuleIsIdentified() {
        let rules = PasswordPolicy.evaluate("x")
        #expect(Set(rules.map(\.id)) == ["length", "uppercase", "number", "special"])
        #expect(rules.allSatisfy { !$0.demand.isEmpty })
    }
}
