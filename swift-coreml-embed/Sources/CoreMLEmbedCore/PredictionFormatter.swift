public enum PredictionFormatter {
  /// Formats class probabilities as "label probability%" lines, best first.
  public static func topLines(probabilities: [String: Double], topK: Int) -> [String] {
    probabilities
      .sorted { $0.value > $1.value }
      .prefix(topK)
      .map { String(format: "%@ %.1f%%", $0.key, $0.value * 100) }
  }
}
