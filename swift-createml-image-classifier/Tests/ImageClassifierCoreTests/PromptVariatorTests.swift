import Testing

@testable import ImageClassifierCore

struct PromptVariatorTests {
  @Test func variation_StartsWithBasePrompt() {
    let variator = PromptVariator()
    var generator: any RandomNumberGenerator = SplitMix64RandomNumberGenerator(seed: 1)

    let result = variator.variation(of: "a cute cat", using: &generator)

    #expect(result.hasPrefix("a cute cat, "))
  }

  @Test func variation_WithSameSeed_IsDeterministic() {
    let variator = PromptVariator()
    var generatorA: any RandomNumberGenerator = SplitMix64RandomNumberGenerator(seed: 7)
    var generatorB: any RandomNumberGenerator = SplitMix64RandomNumberGenerator(seed: 7)

    let resultA = variator.variation(of: "a dog", using: &generatorA)
    let resultB = variator.variation(of: "a dog", using: &generatorB)

    #expect(resultA == resultB)
  }

  @Test func variation_AcrossManyDraws_ProducesMultipleDistinctPrompts() {
    let variator = PromptVariator()
    var generator: any RandomNumberGenerator = SplitMix64RandomNumberGenerator(seed: 3)

    let results = (0..<20).map { _ in variator.variation(of: "a car", using: &generator) }

    #expect(Set(results).count > 5)
  }
}
