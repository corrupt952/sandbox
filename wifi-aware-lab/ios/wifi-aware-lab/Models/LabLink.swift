import Foundation

nonisolated struct LabLink: Identifiable, Equatable, Sendable {
  // MARK: - Nested types

  enum Direction: String, Sendable {
    case incoming = "Incoming"
    case outgoingBrowse = "Outgoing / browse"
    case outgoingPicker = "Outgoing / picker"

    /// Fits the metadata line of a list row, where the full name would push out the values.
    var shortText: String {
      switch self {
      case .incoming: "in"
      case .outgoingBrowse, .outgoingPicker: "out"
      }
    }
  }

  enum State: String, Sendable {
    case setup = "Setup"
    case preparing = "Preparing"
    case waiting = "Waiting"
    case ready = "Ready"
    case failed = "Failed"
    case cancelled = "Cancelled"
    case unknown = "Unknown"

    var isActive: Bool {
      switch self {
      case .setup, .preparing, .waiting, .ready: true
      case .failed, .cancelled, .unknown: false
      }
    }
  }

  // MARK: - Static properties

  static let roundTripHistoryLimit = 60

  // MARK: - Properties

  let id: String
  let direction: Direction
  var state: State
  var deviceID: LabDevice.ID?
  var deviceName: String?
  var localEndpoint: String?
  var remoteEndpoint: String?
  var roundTrips: [Duration] = []
  var metrics: LabLinkMetrics?

  var shortID: String {
    String(id.prefix(8))
  }

  var deviceText: String {
    deviceName ?? "Resolving…"
  }

  var endpointsText: String {
    "local: \(localEndpoint ?? "–") / remote: \(remoteEndpoint ?? "–")"
  }

  var latestRoundTrip: Duration? {
    roundTrips.last
  }

  var roundTripText: String? {
    latestRoundTrip.map { String(format: "RTT %.2f ms", $0.totalMilliseconds) }
  }

  var metricsText: String? {
    metrics?.summary()
  }

  // MARK: - Public methods

  mutating func record(roundTrip: Duration) {
    roundTrips.append(roundTrip)
    if roundTrips.count > Self.roundTripHistoryLimit {
      roundTrips.removeFirst(roundTrips.count - Self.roundTripHistoryLimit)
    }
  }
}
