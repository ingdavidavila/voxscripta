import Foundation
import VoxScriptaCore

/// An error as something an interface can translate, rather than a sentence it
/// must display verbatim.
///
/// `vs_last_error_copy` and `vs_job_error_copy` return English off Apple and
/// always will: `String(localized:)` does not exist in
/// swift-corelibs-foundation, and the shim this project supplies receives the
/// string after interpolation, when the lookup key no longer exists. A Spanish
/// Android interface therefore showed Spanish chrome around English engine
/// errors.
///
/// The engine says what happened; whoever knows the reader's language writes
/// the sentence. `message` stays in the payload so an interface that has no
/// mapping for a code still has something to show — degrading to English beats
/// degrading to nothing.
struct ErrorPayload: Encodable {
    let code: String
    let message: String
    let details: [String: String]

    /// The code used when the failure is a refused argument rather than a
    /// `VoxScriptaError` — a caller passing a null path, say. These are
    /// programming errors on the interface's side and a user should never see
    /// one, which is why they share a single code rather than being
    /// enumerated.
    static let invalidArgumentCode = "invalidArgument"

    init(_ error: any Error) {
        if let known = error as? VoxScriptaError {
            code = known.code
            message = known.errorDescription ?? String(describing: known)
            details = known.details
        } else {
            code = Self.invalidArgumentCode
            message = error.localizedDescription
            details = [:]
        }
    }

    init(argumentMessage: String) {
        code = Self.invalidArgumentCode
        message = argumentMessage
        details = [:]
    }

    /// Deterministic key order, so a caller diffing two payloads sees only
    /// what actually changed.
    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8)
        else {
            // Encoding a dictionary of strings cannot realistically fail, but
            // returning a usable payload beats returning nothing to a caller
            // that is already handling a failure.
            return #"{"code":"\#(Self.invalidArgumentCode)","details":{},"message":""}"#
        }
        return text
    }
}
