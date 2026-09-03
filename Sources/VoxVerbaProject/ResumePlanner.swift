import Foundation
import VoxVerbaCore

/// What resuming an interrupted job requires.
public enum ResumePlan: Sendable, Equatable {
    /// Nothing to do.
    case alreadyComplete
    /// The source file is gone or unreadable.
    case sourceMissing
    /// The source changed; everything downstream is invalid.
    case fullRebuild(reason: String)
    /// Restart from this phase. Earlier phases' artifacts are valid.
    case restart(from: JobState)
    /// Transcription was interrupted; only these chunks remain.
    case resumeTranscription(chunks: [ChunkID])
    /// Polish was interrupted; only these windows remain.
    case resumePolish(windowIndices: [Int])
}

/// Decides where an interrupted or cancelled job picks up (§17).
///
/// Recovery is a consequence of two invariants held everywhere else, not a feature
/// bolted on here:
///
/// - **Atomic commit.** Artifacts are written to a temporary file, `fsync`'d, then
///   renamed into place. A reader never sees a partial file.
/// - **Content-addressed invalidation.** Each stage records a hash over its inputs,
///   so changing the silence threshold invalidates the silence map, chunk plan and
///   transcription — but never the expensive canonical decode.
///
/// A cancelled job is indistinguishable from a crashed one here, which means the
/// cancel path is exercised by every crash-recovery test.
///
/// - Note: Phase 3 implements this, and its gate is that `SIGKILL` at every state
///   followed by resume produces a byte-identical final transcript.
public protocol ResumePlanning: Sendable {
    func plan(for package: ProjectPackage) async throws -> ResumePlan
}

/// Phase 3 implementation site.
public struct ResumePlanner: ResumePlanning {
    public init() {}

    public func plan(for package: ProjectPackage) async throws -> ResumePlan {
        throw VoxVerbaError.notImplemented("ResumePlanner.plan — Phase 3")
    }
}
