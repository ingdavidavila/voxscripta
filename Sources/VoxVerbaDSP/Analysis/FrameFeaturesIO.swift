import Foundation
import VoxVerbaCore

/// Binary serialization for ``FrameFeatures``.
///
/// Analysis costs roughly 0.4% of real time, so a six-hour recording spends about
/// a minute and a half here. Persisting the result — about 12 bytes per frame,
/// so ~26 MB for six hours — means a resume after that stage never pays it again,
/// and re-tuning silence thresholds in the UI is instant.
///
/// A flat binary layout rather than JSON: this is millions of floats, and JSON
/// would be an order of magnitude larger and slower for no benefit.
public extension FrameFeatures {

    /// Magic number and version, so a stale or foreign file is rejected rather
    /// than silently reinterpreted as garbage floats.
    private static var magic: UInt32 { 0x5646_4631 }   // "VFF1"

    /// Serializes to a flat binary blob.
    func serialized() -> Data {
        var data = Data()
        data.reserveCapacity(32 + count * 3 * MemoryLayout<Float>.size)

        func appendUInt32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendInt64(_ value: Int64) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        appendUInt32(Self.magic)
        appendUInt32(UInt32(count))
        appendInt64(geometry.windowDuration.nanoseconds)
        appendInt64(geometry.hopDuration.nanoseconds)
        appendInt64(Int64(geometry.sampleRate))

        for array in [rmsDB, zeroCrossingRate, spectralFlatness] {
            array.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        }
        return data
    }

    /// Reads a blob written by ``serialized()``.
    static func deserialized(from data: Data) throws -> FrameFeatures {
        let headerSize = 4 + 4 + 8 + 8 + 8
        guard data.count >= headerSize else {
            throw VoxVerbaError.projectCorrupt(reason: "the feature file is truncated")
        }

        return try data.withUnsafeBytes { raw -> FrameFeatures in
            func readUInt32(_ offset: Int) -> UInt32 {
                raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
            }
            func readInt64(_ offset: Int) -> Int64 {
                raw.loadUnaligned(fromByteOffset: offset, as: Int64.self).littleEndian
            }

            guard readUInt32(0) == magic else {
                throw VoxVerbaError.projectCorrupt(reason: "the feature file has an unrecognized format")
            }
            let count = Int(readUInt32(4))
            let geometry = FrameGeometry(
                windowDuration: MediaTime(nanoseconds: readInt64(8)),
                hopDuration: MediaTime(nanoseconds: readInt64(16)),
                sampleRate: Int(readInt64(24)))

            let stride = count * MemoryLayout<Float>.size
            guard data.count == headerSize + stride * 3 else {
                throw VoxVerbaError.projectCorrupt(
                    reason: "the feature file declares \(count) frames but is the wrong size")
            }

            func readFloats(_ offset: Int) -> [Float] {
                guard count > 0 else { return [] }
                return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
                    let source = raw.baseAddress!.advanced(by: offset)
                    memcpy(buffer.baseAddress!, source, stride)
                    initialized = count
                }
            }

            return FrameFeatures(
                rmsDB: readFloats(headerSize),
                zeroCrossingRate: readFloats(headerSize + stride),
                spectralFlatness: readFloats(headerSize + stride * 2),
                geometry: geometry)
        }
    }
}
