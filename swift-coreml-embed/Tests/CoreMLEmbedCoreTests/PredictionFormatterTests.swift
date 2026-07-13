import Testing

@testable import CoreMLEmbedCore

struct PredictionFormatterTests {
  @Test func topLines_SortsByProbabilityDescending() {
    let probabilities = ["circle": 0.1, "square": 0.7, "triangle": 0.2]

    let lines = PredictionFormatter.topLines(probabilities: probabilities, topK: 3)

    #expect(lines == ["square 70.0%", "triangle 20.0%", "circle 10.0%"])
  }

  @Test func topLines_WithTopKSmallerThanCount_Truncates() {
    let probabilities = ["a": 0.5, "b": 0.3, "c": 0.2]

    let lines = PredictionFormatter.topLines(probabilities: probabilities, topK: 1)

    #expect(lines == ["a 50.0%"])
  }

  @Test func topLines_WithEmptyProbabilities_ReturnsEmpty() {
    let lines = PredictionFormatter.topLines(probabilities: [:], topK: 3)

    #expect(lines.isEmpty)
  }
}
