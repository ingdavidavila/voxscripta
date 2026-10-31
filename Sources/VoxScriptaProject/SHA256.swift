import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
// swift-crypto, which is the same API without the system framework behind
// it. Apple's is preferred where it exists because it is hardware-backed.
import Crypto
#endif

/// Incremental SHA-256, so large files hash without being loaded.
struct SHA256Streaming {
    private var hasher = SHA256()

    mutating func update(_ bytes: UnsafePointer<UInt8>, count: Int) {
        hasher.update(bufferPointer: UnsafeRawBufferPointer(start: bytes, count: count))
    }

    mutating func update(_ bytes: inout [UInt8], count: Int) {
        bytes.withUnsafeBufferPointer { buffer in
            hasher.update(bufferPointer: UnsafeRawBufferPointer(
                start: buffer.baseAddress, count: count))
        }
    }

    func finalize() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
