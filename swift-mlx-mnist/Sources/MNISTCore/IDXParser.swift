import Foundation

public struct IDXImages: Equatable, Sendable {
  public let count: Int
  public let rows: Int
  public let columns: Int
  public let pixels: [UInt8]
}

public struct IDXLabels: Equatable, Sendable {
  public let count: Int
  public let values: [UInt8]
}

public enum IDXParserError: Error, Equatable {
  case truncatedHeader
  case unexpectedMagic(expected: UInt32, actual: UInt32)
  case truncatedData(expected: Int, actual: Int)
}

/// Parser for the MNIST IDX file format
/// (http://yann.lecun.com/exdb/mnist/). All multi-byte integers are big-endian.
public enum IDXParser {
  private static let imageMagic: UInt32 = 0x0000_0803
  private static let labelMagic: UInt32 = 0x0000_0801

  public static func parseImages(_ data: Data) throws -> IDXImages {
    let bytes = [UInt8](data)
    guard bytes.count >= 16 else {
      throw IDXParserError.truncatedHeader
    }

    let magic = readUInt32(bytes, at: 0)
    guard magic == imageMagic else {
      throw IDXParserError.unexpectedMagic(expected: imageMagic, actual: magic)
    }

    let count = Int(readUInt32(bytes, at: 4))
    let rows = Int(readUInt32(bytes, at: 8))
    let columns = Int(readUInt32(bytes, at: 12))
    let expected = count * rows * columns
    let pixels = Array(bytes[16...])
    guard pixels.count == expected else {
      throw IDXParserError.truncatedData(expected: expected, actual: pixels.count)
    }

    return IDXImages(count: count, rows: rows, columns: columns, pixels: pixels)
  }

  public static func parseLabels(_ data: Data) throws -> IDXLabels {
    let bytes = [UInt8](data)
    guard bytes.count >= 8 else {
      throw IDXParserError.truncatedHeader
    }

    let magic = readUInt32(bytes, at: 0)
    guard magic == labelMagic else {
      throw IDXParserError.unexpectedMagic(expected: labelMagic, actual: magic)
    }

    let count = Int(readUInt32(bytes, at: 4))
    let values = Array(bytes[8...])
    guard values.count == count else {
      throw IDXParserError.truncatedData(expected: count, actual: values.count)
    }

    return IDXLabels(count: count, values: values)
  }

  private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    (UInt32(bytes[offset]) << 24)
      | (UInt32(bytes[offset + 1]) << 16)
      | (UInt32(bytes[offset + 2]) << 8)
      | UInt32(bytes[offset + 3])
  }
}
