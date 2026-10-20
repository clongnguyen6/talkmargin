import Compression
import Foundation

/// Read-only zip reader for Office Open XML packages: central directory plus
/// stored and deflated entries, inflated with the system Compression framework.
/// No ZIP64, no encryption; both are reported as errors, never crashes.
struct ZipArchive {
    enum Failure: Error, Equatable {
        case notZip
        case corrupt(String)
        case unsupported(String)
    }

    private struct Entry {
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let data: Data
    private var entries: [String: Entry] = [:]

    var names: [String] { Array(entries.keys).sorted() }

    init(data: Data) throws {
        self.data = Data(data) // re-based to index 0; slices keep their parent's indices
        let eocd = try Self.findEndOfCentralDirectory(in: data)
        let count = Int(read16(eocd + 10))
        let directorySize = Int(read32(eocd + 12))
        let directoryOffset = Int(read32(eocd + 16))
        if directoryOffset == 0xFFFF_FFFF || count == 0xFFFF {
            throw Failure.unsupported("ZIP64")
        }
        guard directoryOffset + directorySize <= eocd else { throw Failure.corrupt("central directory out of bounds") }

        var cursor = directoryOffset
        for _ in 0..<count {
            guard cursor + 46 <= data.count, read32(cursor) == 0x0201_4B50 else {
                throw Failure.corrupt("bad central directory entry")
            }
            let method = read16(cursor + 10)
            let compressedSize = Int(read32(cursor + 20))
            let uncompressedSize = Int(read32(cursor + 24))
            let nameLength = Int(read16(cursor + 28))
            let extraLength = Int(read16(cursor + 30))
            let commentLength = Int(read16(cursor + 32))
            let localHeaderOffset = Int(read32(cursor + 42))
            guard cursor + 46 + nameLength <= data.count else { throw Failure.corrupt("truncated entry name") }
            if compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF || localHeaderOffset == 0xFFFF_FFFF {
                throw Failure.unsupported("ZIP64")
            }
            let name = String(decoding: data[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            entries[name] = Entry(method: method, compressedSize: compressedSize,
                                  uncompressedSize: uncompressedSize, localHeaderOffset: localHeaderOffset)
            cursor += 46 + nameLength + extraLength + commentLength
        }
    }

    /// The inflated bytes of `name`, or nil when the package has no such part.
    func contents(of name: String) throws -> Data? {
        guard let entry = entries[name] else { return nil }
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, read32(header) == 0x0403_4B50 else {
            throw Failure.corrupt("bad local header for \(name)")
        }
        let start = header + 30 + Int(read16(header + 26)) + Int(read16(header + 28))
        let end = start + entry.compressedSize
        guard end <= data.count else { throw Failure.corrupt("truncated data for \(name)") }
        let compressed = data[start..<end]
        switch entry.method {
        case 0:
            return Data(compressed)
        case 8:
            return try inflate(compressed, expectedSize: entry.uncompressedSize, name: name)
        default:
            throw Failure.unsupported("compression method \(entry.method) for \(name)")
        }
    }

    /// Largest part we are willing to inflate; a damaged directory can claim 4 GB.
    static let maxPartSize = 256 << 20

    private func inflate(_ compressed: Data, expectedSize: Int, name: String) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        guard expectedSize <= Self.maxPartSize else { throw Failure.corrupt("\(name) claims \(expectedSize) bytes") }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { dst -> Int in
            compressed.withUnsafeBytes { src -> Int in
                compression_decode_buffer(dst.baseAddress!.assumingMemoryBound(to: UInt8.self), expectedSize,
                                          src.baseAddress!.assumingMemoryBound(to: UInt8.self), src.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw Failure.corrupt("inflate failed for \(name)") }
        return output
    }

    private static func findEndOfCentralDirectory(in data: Data) throws -> Int {
        guard data.count >= 22 else { throw Failure.notZip }
        guard data[0] == 0x50, data[1] == 0x4B else { throw Failure.notZip }
        let lowest = max(0, data.count - 22 - 0xFFFF)
        var cursor = data.count - 22
        while cursor >= lowest {
            if data[cursor] == 0x50, data[cursor + 1] == 0x4B, data[cursor + 2] == 0x05, data[cursor + 3] == 0x06 {
                return cursor
            }
            cursor -= 1
        }
        throw Failure.corrupt("no end of central directory")
    }

    private func read16(_ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func read32(_ offset: Int) -> UInt32 {
        UInt32(read16(offset)) | UInt32(read16(offset + 2)) << 16
    }
}
