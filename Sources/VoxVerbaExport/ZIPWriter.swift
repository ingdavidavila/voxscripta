import Foundation
import VoxVerbaCore

/// A minimal ZIP writer, enough for the OOXML container a `.docx` is.
///
/// Entries are stored rather than deflated. Word accepts stored entries, a
/// transcript compresses to little anyway at these sizes, and the alternative was
/// a third-party archive dependency for one file format — which is a poor trade
/// in a project that otherwise builds offline with nothing external.
struct ZIPWriter {
    private struct Entry {
        let name: String
        let data: Data
        let crc: UInt32
        let offset: UInt32
    }

    private var entries: [Entry] = []
    private var output = Data()

    /// Adds a file at `path` inside the archive.
    mutating func add(_ data: Data, at path: String) {
        let name = Array(path.utf8)
        let crc = CRC32.checksum(data)
        let offset = UInt32(output.count)

        // Local file header.
        output.append(uint32: 0x0403_4B50)      // signature
        output.append(uint16: 20)               // version needed
        output.append(uint16: 0)                // flags
        output.append(uint16: 0)                // method: stored
        output.append(uint16: 0)                // mod time
        output.append(uint16: 0)                // mod date
        output.append(uint32: crc)
        output.append(uint32: UInt32(data.count))   // compressed size
        output.append(uint32: UInt32(data.count))   // uncompressed size
        output.append(uint16: UInt16(name.count))
        output.append(uint16: 0)                // extra length
        output.append(contentsOf: name)
        output.append(data)

        entries.append(Entry(name: path, data: data, crc: crc, offset: offset))
    }

    /// Finishes the archive and returns its bytes.
    mutating func finalize() -> Data {
        let directoryStart = UInt32(output.count)

        for entry in entries {
            let name = Array(entry.name.utf8)
            output.append(uint32: 0x0201_4B50)  // central directory signature
            output.append(uint16: 20)           // version made by
            output.append(uint16: 20)           // version needed
            output.append(uint16: 0)            // flags
            output.append(uint16: 0)            // method: stored
            output.append(uint16: 0)            // mod time
            output.append(uint16: 0)            // mod date
            output.append(uint32: entry.crc)
            output.append(uint32: UInt32(entry.data.count))
            output.append(uint32: UInt32(entry.data.count))
            output.append(uint16: UInt16(name.count))
            output.append(uint16: 0)            // extra
            output.append(uint16: 0)            // comment
            output.append(uint16: 0)            // disk number
            output.append(uint16: 0)            // internal attributes
            output.append(uint32: 0)            // external attributes
            output.append(uint32: entry.offset)
            output.append(contentsOf: name)
        }

        let directorySize = UInt32(output.count) - directoryStart
        output.append(uint32: 0x0605_4B50)      // end of central directory
        output.append(uint16: 0)                // disk number
        output.append(uint16: 0)                // directory start disk
        output.append(uint16: UInt16(entries.count))
        output.append(uint16: UInt16(entries.count))
        output.append(uint32: directorySize)
        output.append(uint32: directoryStart)
        output.append(uint16: 0)                // comment length
        return output
    }
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
    mutating func append(uint32 value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

/// CRC-32, as ZIP requires for every entry.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }
}
