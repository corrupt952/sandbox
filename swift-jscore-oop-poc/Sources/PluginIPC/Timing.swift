import Foundation

public enum Timing {
  public static func millis(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000
      + Double(duration.components.attoseconds) * 1e-15
  }
}

/// `p95` uses nearest-rank so a 30-sample run reports an observation that actually
/// happened rather than an interpolation between two that did not.
public struct Percentiles {
  public let count: Int
  public let min: Double
  public let p50: Double
  public let p95: Double
  public let max: Double
  public let mean: Double

  public init(_ samples: [Double]) {
    precondition(!samples.isEmpty, "no samples")
    let sorted = samples.sorted()
    count = sorted.count
    min = sorted.first!
    max = sorted.last!
    mean = sorted.reduce(0, +) / Double(sorted.count)
    p50 = Percentiles.nearestRank(sorted, 0.50)
    p95 = Percentiles.nearestRank(sorted, 0.95)
  }

  private static func nearestRank(_ sorted: [Double], _ q: Double) -> Double {
    let rank = Int((q * Double(sorted.count)).rounded(.up))
    return sorted[Swift.max(0, Swift.min(sorted.count - 1, rank - 1))]
  }

  public var line: String {
    String(
      format: "n=%d  min=%.2f  p50=%.2f  p95=%.2f  max=%.2f  mean=%.2f (ms)",
      count, min, p50, p95, max, mean)
  }
}
