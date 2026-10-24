import Compression
import Foundation

public enum Gzip {
    public enum Failure: Error { case compressionFailed }

    /// IEEE CRC-32 (reflected polynomial), RFC 1952 trailer checksum.
    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb8_8320 : 0)
            }
        }
        return crc ^ 0xffff_ffff
    }

    public static func compress(_ data: Data) throws -> Data {
        // Compression's ZLIB algorithm emits raw RFC 1951 DEFLATE, without a zlib wrapper.
        var deflated: Data
        if data.isEmpty {
            deflated = Data([0x03, 0x00]) // Final empty fixed-Huffman block.
        } else {
            var capacity = data.count + data.count / 8 + 1_024
            var encoded: Data?
            for _ in 0..<4 {
                var destination = Data(count: capacity)
                let destinationCapacity = capacity
                let count = destination.withUnsafeMutableBytes { output in
                    data.withUnsafeBytes { input in
                        compression_encode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, destinationCapacity,
                                                  input.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                                  nil, COMPRESSION_ZLIB)
                    }
                }
                if count > 0 { destination.count = count; encoded = destination; break }
                capacity *= 2
            }
            guard let encoded else { throw Failure.compressionFailed }
            deflated = encoded
        }
        var gzip = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0, 0xff])
        gzip.append(deflated)
        appendLittleEndian(crc32(data), to: &gzip)
        appendLittleEndian(UInt32(truncatingIfNeeded: data.count), to: &gzip)
        return gzip
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
}
