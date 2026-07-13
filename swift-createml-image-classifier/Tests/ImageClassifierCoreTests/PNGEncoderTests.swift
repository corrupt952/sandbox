import CoreGraphics
import ImageIO
import Testing

@testable import ImageClassifierCore

struct PNGEncoderTests {
  @Test func encode_WithRenderedImage_ProducesDecodablePNG() throws {
    let renderer = SyntheticSampleRenderer()
    var generator = SplitMix64RandomNumberGenerator(seed: 7)
    let image = try #require(renderer.render(shape: .circle, using: &generator))

    let data = try #require(PNGEncoder.encode(image))

    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(decoded.width == image.width)
    #expect(decoded.height == image.height)
  }
}
