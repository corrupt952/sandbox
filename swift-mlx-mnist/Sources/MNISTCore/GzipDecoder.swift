import Compression
import Foundation

public enum GzipError: Error, Equatable {
  case notGzip
  case unsupportedMethod
  case truncated
  case decodeFailed
}

/// Minimal gzip (RFC 1952) decoder built on Apple's Compression framework.
/// Compression only decodes raw DEFLATE (RFC 1951), so this strips the gzip
/// header and trailer and inflates the DEFLATE payload in between.
public enum GzipDecoder {
  public static func inflate(_ data: Data) throws -> Data {
    let bytes = [UInt8](data)
    guard bytes.count >= 18 else {
      throw GzipError.truncated
    }
    guard bytes[0] == 0x1F, bytes[1] == 0x8B else {
      throw GzipError.notGzip
    }
    guard bytes[2] == 0x08 else {
      throw GzipError.unsupportedMethod
    }

    let flags = bytes[3]
    var offset = 10

    // FEXTRA: 2-byte length followed by that many bytes.
    if flags & 0x04 != 0 {
      guard offset + 2 <= bytes.count else {
        throw GzipError.truncated
      }
      let extraLength = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
      offset += 2 + extraLength
    }
    // FNAME / FCOMMENT: zero-terminated strings.
    if flags & 0x08 != 0 {
      offset = try skipZeroTerminated(bytes, from: offset)
    }
    if flags & 0x10 != 0 {
      offset = try skipZeroTerminated(bytes, from: offset)
    }
    // FHCRC: 2-byte header checksum.
    if flags & 0x02 != 0 {
      offset += 2
    }

    let deflateEnd = bytes.count - 8
    guard offset < deflateEnd else {
      throw GzipError.truncated
    }

    // Trailer stores the uncompressed size (mod 2^32) as the final 4 bytes.
    let isize =
      Int(bytes[bytes.count - 4])
      | (Int(bytes[bytes.count - 3]) << 8)
      | (Int(bytes[bytes.count - 2]) << 16)
      | (Int(bytes[bytes.count - 1]) << 24)
    guard isize > 0 else {
      throw GzipError.truncated
    }

    var destination = [UInt8](repeating: 0, count: isize)
    let written = destination.withUnsafeMutableBufferPointer { destinationBuffer in
      bytes.withUnsafeBufferPointer { sourceBuffer in
        compression_decode_buffer(
          destinationBuffer.baseAddress!,
          isize,
          sourceBuffer.baseAddress! + offset,
          deflateEnd - offset,
          nil,
          COMPRESSION_ZLIB
        )
      }
    }

    guard written == isize else {
      throw GzipError.decodeFailed
    }
    return Data(destination)
  }

  private static func skipZeroTerminated(_ bytes: [UInt8], from start: Int) throws -> Int {
    var offset = start
    while offset < bytes.count, bytes[offset] != 0 {
      offset += 1
    }
    guard offset < bytes.count else {
      throw GzipError.truncated
    }
    return offset + 1
  }
}
