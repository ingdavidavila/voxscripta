import Foundation
import VoxScriptaCore
import VoxScriptaDSP

/// The canonical decoder this platform actually ships.
///
/// There are two implementations of ``CanonicalDecoding``: ``CanonicalDecoder``
/// is AVFoundation's and exists only on Apple's platforms, and
/// ``PortableDecoder`` is FFmpeg's and exists everywhere. A test whose subject
/// is one of them names it directly. A test that only needs *a* decoder — to
/// build a project, or to assert a contract both are meant to honour, such as
/// the error a missing file produces — takes this one instead.
///
/// That is a better answer than guarding those tests off Apple, for two
/// reasons. They keep running on Linux, where they are the tests that matter;
/// and the contract they assert gets checked against the decoder that platform
/// really uses, rather than only against Apple's.
public func platformDecoder(bufferDuration: TimeInterval = 10) -> any CanonicalDecoding {
    #if canImport(AVFoundation)
    CanonicalDecoder(bufferDuration: bufferDuration)
    #else
    PortableDecoder(bufferDuration: bufferDuration)
    #endif
}
