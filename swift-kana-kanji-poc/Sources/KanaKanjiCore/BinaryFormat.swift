import Foundation

/// Little-endian primitives for the compiled dictionary files.
/// Values are assembled byte by byte so the reader never has to care about
/// alignment of a memory-mapped buffer.
enum LE {
  static func append(_ value: UInt16, to bytes: inout [UInt8]) {
    bytes.append(UInt8(truncatingIfNeeded: value))
    bytes.append(UInt8(truncatingIfNeeded: value >> 8))
  }

  static func append(_ value: UInt32, to bytes: inout [UInt8]) {
    bytes.append(UInt8(truncatingIfNeeded: value))
    bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    bytes.append(UInt8(truncatingIfNeeded: value >> 16))
    bytes.append(UInt8(truncatingIfNeeded: value >> 24))
  }

  static func append(_ value: Int16, to bytes: inout [UInt8]) {
    append(UInt16(bitPattern: value), to: &bytes)
  }

  static func u16(_ buffer: UnsafeRawBufferPointer, _ offset: Int) -> UInt16 {
    UInt16(buffer[offset]) | (UInt16(buffer[offset + 1]) << 8)
  }

  static func u32(_ buffer: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
    UInt32(buffer[offset]) | (UInt32(buffer[offset + 1]) << 8)
      | (UInt32(buffer[offset + 2]) << 16) | (UInt32(buffer[offset + 3]) << 24)
  }

  static func i16(_ buffer: UnsafeRawBufferPointer, _ offset: Int) -> Int16 {
    Int16(bitPattern: u16(buffer, offset))
  }
}

enum FormatError: Error, CustomStringConvertible {
  case badMagic(String)
  case unsupportedVersion(UInt32)
  case truncated(String)
  case missingResource(String)
  case malformedSource(String)

  var description: String {
    switch self {
    case .badMagic(let path): return "not a kkc data file: \(path)"
    case .unsupportedVersion(let v): return "unsupported data version: \(v)"
    case .truncated(let path): return "truncated data file: \(path)"
    case .missingResource(let path): return "missing resource: \(path)"
    case .malformedSource(let detail): return "malformed source data: \(detail)"
    }
  }
}
