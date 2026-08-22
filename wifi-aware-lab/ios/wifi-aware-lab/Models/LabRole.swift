import Foundation

nonisolated enum LabRole: String, Sendable {
  case publisher = "Publisher"
  case subscriber = "Subscriber"

  // MARK: - Nested types

  enum Status: Equatable, Sendable {
    case stopped
    case starting
    case setup
    case waiting
    case ready
    case browsing(foundCount: Int)
    case failed
    case unknown

    var isRunning: Bool {
      switch self {
      case .starting, .setup, .waiting, .ready, .browsing: true
      case .stopped, .failed, .unknown: false
      }
    }
  }

  /// How a publisher or browser run ended.
  enum Outcome: Equatable, Sendable {
    case cancelled
    case finished
    case failed(LabFailure)
  }
}
