import Foundation
import Testing

@testable import MNISTCore

struct GzipDecoderTests {
  // `printf 'MNIST-gzip-roundtrip' | gzip -n`
  private let fixture = Data([
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xf3, 0xf5,
    0xf3, 0x0c, 0x0e, 0xd1, 0x4d, 0xaf, 0xca, 0x2c, 0xd0, 0x2d, 0xca, 0x2f,
    0xcd, 0x4b, 0x29, 0x29, 0xca, 0x2c, 0x00, 0x00, 0x70, 0x40, 0xf8, 0x9e,
    0x14, 0x00, 0x00, 0x00,
  ])

  @Test func inflate_WithValidGzip_RestoresOriginalBytes() throws {
    let result = try GzipDecoder.inflate(fixture)

    #expect(String(data: result, encoding: .utf8) == "MNIST-gzip-roundtrip")
  }

  @Test func inflate_WithoutGzipMagic_ThrowsNotGzip() {
    let data = Data(repeating: 0x41, count: 20)

    #expect(throws: GzipError.notGzip) {
      try GzipDecoder.inflate(data)
    }
  }

  @Test func inflate_WithTruncatedData_ThrowsTruncated() {
    let data = Data([0x1f, 0x8b, 0x08])

    #expect(throws: GzipError.truncated) {
      try GzipDecoder.inflate(data)
    }
  }
}
