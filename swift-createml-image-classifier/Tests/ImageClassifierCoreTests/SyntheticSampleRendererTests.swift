import CoreGraphics
import Testing

@testable import ImageClassifierCore

struct SyntheticSampleRendererTests {
  @Test func render_WithDefaultCanvasSize_Produces128x128Image() {
    let renderer = SyntheticSampleRenderer()
    var generator = SplitMix64RandomNumberGenerator(seed: 1)

    let image = renderer.render(shape: .circle, using: &generator)

    #expect(image?.width == 128)
    #expect(image?.height == 128)
  }

  @Test(arguments: SyntheticShape.allCases)
  func render_WithAnyShape_ProducesImage(shape: SyntheticShape) {
    let renderer = SyntheticSampleRenderer()
    var generator = SplitMix64RandomNumberGenerator(seed: 2)

    let image = renderer.render(shape: shape, using: &generator)

    #expect(image != nil)
  }

  @Test func render_WithSameSeed_ProducesIdenticalPNGData() throws {
    let renderer = SyntheticSampleRenderer()
    var generatorA = SplitMix64RandomNumberGenerator(seed: 42)
    var generatorB = SplitMix64RandomNumberGenerator(seed: 42)

    let imageA = try #require(renderer.render(shape: .triangle, using: &generatorA))
    let imageB = try #require(renderer.render(shape: .triangle, using: &generatorB))

    #expect(PNGEncoder.encode(imageA) == PNGEncoder.encode(imageB))
  }

  @Test func render_WithDifferentSeeds_ProducesDifferentPNGData() throws {
    let renderer = SyntheticSampleRenderer()
    var generatorA = SplitMix64RandomNumberGenerator(seed: 1)
    var generatorB = SplitMix64RandomNumberGenerator(seed: 2)

    let imageA = try #require(renderer.render(shape: .square, using: &generatorA))
    let imageB = try #require(renderer.render(shape: .square, using: &generatorB))

    #expect(PNGEncoder.encode(imageA) != PNGEncoder.encode(imageB))
  }
}
