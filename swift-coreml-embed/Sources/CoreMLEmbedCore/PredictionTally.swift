public struct PredictionTally: Sendable {
  public private(set) var total = 0
  public private(set) var correct = 0

  public init() {}

  public mutating func add(predicted: String, expected: String) {
    total += 1
    if predicted == expected {
      correct += 1
    }
  }

  public var accuracy: Double {
    total == 0 ? 0 : Double(correct) / Double(total)
  }
}
