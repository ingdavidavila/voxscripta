import Foundation
import VoxVerbaCore

/// Produces the CLEAN variant (§12) with no language model involved.
///
/// Modern on-device ASR already emits punctuated, capitalized text, so everything
/// CLEAN asks for — punctuation, paragraph breaks, capitalization fixes, artifact
/// repair, disfluency removal — is reachable with deterministic rules over the
/// structured transcript plus the measured pause data.
///
/// That makes CLEAN's hallucination risk exactly zero, which matters because it is
/// the variant most users will actually read.
///
/// - Note: Phase 4 implements this.
public struct CleanParameters: Hashable, Sendable, Codable {
    /// Remove filler words drawn from the closed lexicon.
    public var removeFillers: Bool
    /// Collapse stutters and immediate word repetitions.
    public var collapseRepetitions: Bool
    /// Insert paragraph breaks from measured pause durations.
    public var paragraphsFromPauses: Bool
    /// Repair known ASR artifacts (stray tokens, doubled punctuation).
    public var repairArtifacts: Bool

    public init(
        removeFillers: Bool = true,
        collapseRepetitions: Bool = true,
        paragraphsFromPauses: Bool = true,
        repairArtifacts: Bool = true
    ) {
        self.removeFillers = removeFillers
        self.collapseRepetitions = collapseRepetitions
        self.paragraphsFromPauses = paragraphsFromPauses
        self.repairArtifacts = repairArtifacts
    }

    public static let `default` = CleanParameters()
}

public protocol CleanProcessing: Sendable {
    func process(
        verbatim: Transcript,
        parameters: CleanParameters,
        silenceParameters: SilenceParameters
    ) throws -> Transcript
}

/// Phase 4 implementation site.
public struct CleanProcessor: CleanProcessing {
    public init() {}

    public func process(
        verbatim: Transcript,
        parameters: CleanParameters,
        silenceParameters: SilenceParameters
    ) throws -> Transcript {
        throw VoxVerbaError.notImplemented("CleanProcessor.process — Phase 4")
    }
}
