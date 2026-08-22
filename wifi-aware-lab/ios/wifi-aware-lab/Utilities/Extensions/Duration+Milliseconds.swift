import Foundation

nonisolated extension Duration {
  var totalMilliseconds: Double {
    let parts = components
    return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1_000_000_000_000_000
  }
}
