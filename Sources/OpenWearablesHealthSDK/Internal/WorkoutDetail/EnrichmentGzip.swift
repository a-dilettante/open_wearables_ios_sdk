import Foundation
import Compression

/// Deterministic gzip framing for enrichment chunk bodies.
///
/// The wire contract sends every stream chunk with `Content-Encoding: gzip`, so the
/// bytes on disk are already the compressed body: the background `URLSession` uploads
/// the file verbatim and never re-encodes it.
///
/// Determinism is a requirement, not a nicety — the replay test asserts that the same
/// collected detail produces byte-identical chunk files, and a gzip header carrying a
/// modification time would break that. The header therefore pins mtime to 0 and the
/// OS byte to "unknown".
enum EnrichmentGzip {

    /// gzip magic + deflate method + no flags + zero mtime + no extra flags + unknown OS.
    private static let header: [UInt8] = [0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff]

    /// Compresses `data` into a complete gzip member.
    ///
    /// Apple's `COMPRESSION_ZLIB` emits a raw DEFLATE stream, which is exactly the
    /// payload a gzip member wraps, so the two compose without a third-party zlib.
    static func compress(_ data: Data) -> Data {
        var out = Data(header)
        out.append(deflate(data))
        appendLittleEndian(&out, crc32(data))
        // ISIZE is the uncompressed size modulo 2^32, per RFC 1952.
        appendLittleEndian(&out, UInt32(truncatingIfNeeded: data.count))
        return out
    }

    /// Inverse of `compress`, used by the round-trip test and by the outbox self-check.
    /// Returns `nil` for anything that is not a gzip member this type could have made.
    static func decompress(_ data: Data) -> Data? {
        guard data.count > header.count + 8,
              data[data.startIndex] == 0x1f,
              data[data.startIndex + 1] == 0x8b,
              data[data.startIndex + 2] == 0x08,
              // Only the no-extra-fields flag layout this type writes is accepted.
              data[data.startIndex + 3] == 0x00 else { return nil }

        let body = data.subdata(in: (data.startIndex + header.count)..<(data.endIndex - 8))
        let expectedSize = Int(readLittleEndian(data, at: data.endIndex - 4))
        guard let inflated = inflate(body, expectedSize: expectedSize) else { return nil }
        guard crc32(inflated) == readLittleEndian(data, at: data.endIndex - 8) else { return nil }
        return inflated
    }

    // MARK: - DEFLATE

    private static func deflate(_ data: Data) -> Data {
        guard !data.isEmpty else { return storedBlocks(data) }

        // Compression can expand incompressible input, so the destination is sized
        // above the source rather than at it.
        let capacity = data.count + (data.count / 2) + 128
        var destination = [UInt8](repeating: 0, count: capacity)

        let written = data.withUnsafeBytes { source -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(&destination, capacity, base, data.count, nil, COMPRESSION_ZLIB)
        }

        // A zero return means the encoder could not fit its output. Falling back to
        // stored (uncompressed) DEFLATE blocks keeps the file a valid gzip member
        // instead of failing the upload, which is the only outcome that matters here.
        guard written > 0 else { return storedBlocks(data) }
        return Data(destination[0..<written])
    }

    private static func inflate(_ data: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }
        var destination = [UInt8](repeating: 0, count: expectedSize)
        let written = data.withUnsafeBytes { source -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(&destination, expectedSize, base, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written == expectedSize else { return nil }
        return Data(destination[0..<written])
    }

    /// RFC 1951 stored blocks: `BFINAL|BTYPE=00`, then LEN and its ones-complement,
    /// then the literal bytes. Each block carries at most 65535 bytes.
    private static func storedBlocks(_ data: Data) -> Data {
        var out = Data()
        let maximum = 65_535
        var offset = data.startIndex

        repeat {
            let end = min(offset + maximum, data.endIndex)
            let slice = data[offset..<end]
            let length = UInt16(slice.count)
            let isFinal = end == data.endIndex

            out.append(isFinal ? 0x01 : 0x00)
            out.append(UInt8(length & 0xff))
            out.append(UInt8(length >> 8))
            out.append(UInt8(~length & 0xff))
            out.append(UInt8((~length >> 8) & 0xff))
            out.append(contentsOf: slice)

            offset = end
        } while offset < data.endIndex

        return out
    }

    // MARK: - CRC-32 (RFC 1952)

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xFFFF_FFFF
        for byte in data {
            value = crcTable[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
        }
        return value ^ 0xFFFF_FFFF
    }

    // MARK: - Scalars

    private static func appendLittleEndian(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }

    private static func readLittleEndian(_ data: Data, at index: Data.Index) -> UInt32 {
        UInt32(data[index])
            | (UInt32(data[index + 1]) << 8)
            | (UInt32(data[index + 2]) << 16)
            | (UInt32(data[index + 3]) << 24)
    }
}
