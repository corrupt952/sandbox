import Testing

@testable import CoreMLEmbedCore

struct PredictionTallyTests {
  @Test func accuracy_WithMixedResults_ReturnsCorrectRatio() {
    var tally = PredictionTally()

    tally.add(predicted: "circle", expected: "circle")
    tally.add(predicted: "square", expected: "circle")
    tally.add(predicted: "triangle", expected: "triangle")
    tally.add(predicted: "circle", expected: "circle")

    #expect(tally.total == 4)
    #expect(tally.correct == 3)
    #expect(tally.accuracy == 0.75)
  }

  @Test func accuracy_WithNoSamples_ReturnsZero() {
    let tally = PredictionTally()

    #expect(tally.accuracy == 0)
  }
}
