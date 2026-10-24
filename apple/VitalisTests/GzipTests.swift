import Foundation
import XCTest
import zlib
import VitalisKit

final class GzipTests: XCTestCase {
    func testCRC32KnownVector() {
        XCTAssertEqual(Gzip.crc32(Data("123456789".utf8)), 0xcbf4_3926)
        XCTAssertEqual(Gzip.crc32(Data()), 0)
    }

    func testGzipRoundTripWithIndependentZlibDecoder() throws {
        // zlib's gzip mode validates the header, CRC and ISIZE, independently of Compression.
        let inputs = [Data(), Data("hello Vitalis".utf8), Data(repeating: 0x61, count: 1_000_000),
                      Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0 &* 31) })]
        for input in inputs {
            let gzip = try Gzip.compress(input)
            XCTAssertEqual(Array(gzip.prefix(3)), [0x1f, 0x8b, 0x08])
            XCTAssertEqual(try inflateGzip(gzip, capacity: max(input.count + 1, 1)), input)
        }
    }

    private func inflateGzip(_ input: Data, capacity: Int) throws -> Data {
        var stream = z_stream()
        let status = inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        XCTAssertEqual(status, Z_OK)
        defer { inflateEnd(&stream) }
        var output = Data(count: capacity)
        let result = output.withUnsafeMutableBytes { destination in
            input.withUnsafeBytes { source in
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress!)
                stream.avail_in = uInt(input.count)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress!
                stream.avail_out = uInt(capacity)
                return inflate(&stream, Z_FINISH)
            }
        }
        XCTAssertEqual(result, Z_STREAM_END)
        guard result == Z_STREAM_END else { throw Gzip.Failure.compressionFailed }
        output.count = Int(stream.total_out)
        return output
    }
}
