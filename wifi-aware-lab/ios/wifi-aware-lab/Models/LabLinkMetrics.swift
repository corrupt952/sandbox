import Foundation

nonisolated struct LabLinkMetrics: Equatable, Sendable {
  // MARK: - Properties

  let signalStrength: Double?
  let throughputCapacity: Double?
  let transmitLatency: Duration?
  let deviceName: String?

  // MARK: - Public methods

  func summary() -> String {
    let signal = signalStrength.map { String(format: "%.2f", $0) } ?? "–"
    let capacity = throughputCapacity.map { String(format: "%.2f Mbps", $0) } ?? "–"
    let latency = transmitLatency.map { String(format: "%.2f ms", $0.totalMilliseconds) } ?? "–"
    return "signal \(signal) · capacity \(capacity) · tx \(latency)"
  }
}
