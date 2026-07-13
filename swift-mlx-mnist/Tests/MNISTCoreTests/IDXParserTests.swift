import Foundation
import Testing

@testable import MNISTCore

struct IDXParserTests {
  private func bigEndian(_ value: UInt32) -> [UInt8] {
    [
      UInt8((value >> 24) & 0xFF),
      UInt8((value >> 16) & 0xFF),
      UInt8((value >> 8) & 0xFF),
      UInt8(value & 0xFF),
    ]
  }

  @Test func parseImages_WithValidData_ReturnsDimensionsAndPixels() throws {
    // 2 images, 2x3 pixels each = 12 pixel bytes.
    var bytes = bigEndian(0x0000_0803) + bigEndian(2) + bigEndian(2) + bigEndian(3)
    bytes += Array(0..<12).map { UInt8($0) }

    let images = try IDXParser.parseImages(Data(bytes))

    #expect(images.count == 2)
    #expect(images.rows == 2)
    #expect(images.columns == 3)
    #expect(images.pixels == Array(0..<12).map { UInt8($0) })
  }

  @Test func parseImages_WithWrongMagic_ThrowsUnexpectedMagic() {
    let bytes = bigEndian(0x0000_0801) + bigEndian(0) + bigEndian(0) + bigEndian(0)

    #expect(throws: IDXParserError.unexpectedMagic(expected: 0x0000_0803, actual: 0x0000_0801)) {
      try IDXParser.parseImages(Data(bytes))
    }
  }

  @Test func parseImages_WithTruncatedPixels_ThrowsTruncatedData() {
    // Header claims 12 pixels but only 5 are present.
    var bytes = bigEndian(0x0000_0803) + bigEndian(2) + bigEndian(2) + bigEndian(3)
    bytes += Array(0..<5).map { UInt8($0) }

    #expect(throws: IDXParserError.truncatedData(expected: 12, actual: 5)) {
      try IDXParser.parseImages(Data(bytes))
    }
  }

  @Test func parseImages_WithShortHeader_ThrowsTruncatedHeader() {
    #expect(throws: IDXParserError.truncatedHeader) {
      try IDXParser.parseImages(Data([0x00, 0x00, 0x08]))
    }
  }

  @Test func parseLabels_WithValidData_ReturnsValues() throws {
    var bytes = bigEndian(0x0000_0801) + bigEndian(4)
    bytes += [7, 2, 1, 9]

    let labels = try IDXParser.parseLabels(Data(bytes))

    #expect(labels.count == 4)
    #expect(labels.values == [7, 2, 1, 9])
  }

  @Test func parseLabels_WithWrongMagic_ThrowsUnexpectedMagic() {
    let bytes = bigEndian(0x0000_0803) + bigEndian(0)

    #expect(throws: IDXParserError.unexpectedMagic(expected: 0x0000_0801, actual: 0x0000_0803)) {
      try IDXParser.parseLabels(Data(bytes))
    }
  }
}
