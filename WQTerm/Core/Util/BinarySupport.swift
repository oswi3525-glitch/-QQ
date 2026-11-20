import Foundation
import Compression

/// Nén/giải nén DEFLATE thô (RFC 1951) — đúng định dạng ZIP method 8.
///
/// Dùng `Compression` của Apple (`COMPRESSION_ZLIB` là DEFLATE thô, **không**
/// có header zlib), nên không cần thêm thư viện ngoài như ZIPFoundation.
enum Deflate {
    static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + data.count / 8 + 1024
        var output = [UInt8](repeating: 0, count: capacity)

        let written = data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
            guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) -> Int in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(destinationBase, capacity,
                                                 sourceBase, data.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }

        guard written > 0 else { return nil }
        return Data(output[0..<written])
    }

    /// Giải nén với kích thước đích đã biết (lấy từ central directory).
    static func decompress(_ data: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }
        guard !data.isEmpty else { return nil }
        var output = [UInt8](repeating: 0, count: expectedSize)

        let written = data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
            guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) -> Int in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(destinationBase, expectedSize,
                                                 sourceBase, data.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }

        guard written > 0 else { return nil }
        return Data(output[0..<written])
    }
}

/// CRC-32 (IEEE 802.3) — bắt buộc cho header ZIP.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for byte in buffer.bindMemory(to: UInt8.self) {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// CRC của file lớn, đọc theo chunk 1MB để không nạp cả file vào RAM.
    static func checksum(of url: URL) throws -> UInt32 {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        defer { try? handle.close() }

        var crc: UInt32 = 0xFFFF_FFFF
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            chunk.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                for byte in buffer.bindMemory(to: UInt8.self) {
                    crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
                }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - Little-endian helpers

extension Data {
    mutating func appendLE16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLE32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    /// Đọc UInt16 little-endian; trả 0 nếu vượt biên (không bao giờ crash).
    func le16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        let start = index(startIndex, offsetBy: offset)
        return UInt16(self[start]) | (UInt16(self[start + 1]) << 8)
    }

    /// Đọc UInt32 little-endian; trả 0 nếu vượt biên.
    func le32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        let start = index(startIndex, offsetBy: offset)
        return UInt32(self[start])
            | (UInt32(self[start + 1]) << 8)
            | (UInt32(self[start + 2]) << 16)
            | (UInt32(self[start + 3]) << 24)
    }
}
