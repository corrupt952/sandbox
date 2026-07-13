import Testing

@testable import MNISTCore

struct SplitMix64RandomNumberGeneratorTests {
  @Test func next_WithSameSeed_ProducesIdenticalSequence() {
    var generatorA = SplitMix64RandomNumberGenerator(seed: 42)
    var generatorB = SplitMix64RandomNumberGenerator(seed: 42)

    let sequenceA = (0..<10).map { _ in generatorA.next() }
    let sequenceB = (0..<10).map { _ in generatorB.next() }

    #expect(sequenceA == sequenceB)
  }

  @Test func next_WithDifferentSeeds_ProducesDifferentSequences() {
    var generatorA = SplitMix64RandomNumberGenerator(seed: 1)
    var generatorB = SplitMix64RandomNumberGenerator(seed: 2)

    let sequenceA = (0..<10).map { _ in generatorA.next() }
    let sequenceB = (0..<10).map { _ in generatorB.next() }

    #expect(sequenceA != sequenceB)
  }
}
