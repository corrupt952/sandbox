import Foundation

/// Split from the view model so that what happened and how it reads stay separate concerns.
@MainActor
struct LabEventLog {
  // MARK: - Static properties

  private static let limit = 500

  // MARK: - Properties

  private(set) var lines: [String] = []

  var latest: String? {
    lines.last
  }

  // MARK: - Private properties

  private let dateGenerator: () -> Date
  private let formatter: DateFormatter

  // MARK: - Initialization

  init(dateGenerator: @escaping () -> Date = Date.init) {
    self.dateGenerator = dateGenerator
    formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
  }

  // MARK: - Public methods

  mutating func append(_ message: String) {
    lines.append("\(formatter.string(from: dateGenerator()))  \(message)")
    if lines.count > Self.limit {
      lines.removeFirst(lines.count - Self.limit)
    }
  }

  mutating func clear() {
    lines.removeAll()
    append("Log cleared")
  }

  // MARK: - Session

  mutating func appendSessionStart(id: String, isSupported: Bool, environment: LabEnvironment) {
    append("Session \(id) started")
    append("Wi-Fi Aware supported: \(isSupported)")
    append("Service declared: \(environment.isServiceDeclared) (\(environment.serviceName))")
  }

  mutating func appendPairedDeviceCount(_ count: Int) {
    append("Paired-device list updated: \(count)")
  }

  mutating func appendPairedDeviceFailure(_ error: any Error) {
    append("Paired-device monitor failed: \(error)")
  }

  // MARK: - Roles

  mutating func appendRoleRequested(_ role: LabRole, settings: LabRadioSettings) {
    switch role {
    case .publisher:
      append("Publisher requested (\(settings.summary()))")
    case .subscriber:
      append("Subscriber browse requested (active \(settings.activeDuration.rawValue))")
    }
  }

  mutating func appendRoleAlreadyRunning(_ role: LabRole) {
    switch role {
    case .publisher:
      append("Publisher is already active")
    case .subscriber:
      append("Subscriber browser is already active")
    }
  }

  mutating func appendRoleStopping(_ role: LabRole) {
    switch role {
    case .publisher:
      append("Stopping publisher")
    case .subscriber:
      append("Stopping subscriber browser")
    }
  }

  mutating func appendRoleState(_ role: LabRole, status: LabRole.Status, failure: LabFailure?) {
    switch status {
    case .waiting:
      append("\(role.rawValue) waiting: \(failure?.text ?? "–")")
    case .ready:
      append(role == .publisher ? "Publisher is listening" : "Subscriber is browsing")
    case .failed:
      append("\(role.rawValue) state failed: \(failure?.text ?? "–")")
    default:
      break
    }
  }

  mutating func appendRoleOutcome(_ outcome: LabRole.Outcome, for role: LabRole) {
    switch outcome {
    case .cancelled:
      append(role == .publisher ? "Publisher stopped" : "Subscriber browser stopped")
    case .finished:
      if role == .subscriber {
        append("Subscriber browse finished")
      }
    case .failed(let failure):
      append("\(role.rawValue) failed: \(failure.text)")
    }
  }

  // MARK: - Pairing

  mutating func appendAdvertiserOpened() {
    append("Publisher pairing UI opened")
  }

  mutating func appendPickerOpened() {
    append("Subscriber device picker opened")
  }

  mutating func appendEndpointSelected(_ name: String) {
    append("DevicePicker selected \(name)")
  }

  mutating func appendConnecting(to name: String) {
    append("Discovered \(name), connecting")
  }

  // MARK: - Links

  mutating func appendLinkAdded(_ link: LabLink, activeCount: Int, maximum: Int) {
    append(
      "Connection added [\(link.shortID)] \(link.direction.rawValue) (\(activeCount)/\(maximum))"
    )
  }

  mutating func appendLinkState(_ linkID: String, state: LabLink.State, failure: LabFailure?) {
    if let failure {
      switch state {
      case .waiting:
        append("Connection waiting [\(shortID(linkID))]: \(failure.text)")
      case .failed:
        append("Connection failed [\(shortID(linkID))]: \(failure.text)")
      default:
        break
      }
    }
    append("Connection [\(shortID(linkID))] → \(state.rawValue)")
  }

  mutating func appendRoundTrip(_ roundTrip: Duration, linkID: String) {
    append(String(format: "RTT [\(shortID(linkID))] %.2f ms", roundTrip.totalMilliseconds))
  }

  // MARK: - Messages

  mutating func appendMessageSent(_ message: LabMessage, linkID: String) {
    append(
      "TX \(message.kind.rawValue) [\(shortID(linkID))] id=\(message.id.uuidString.prefix(8))"
    )
  }

  mutating func appendMessageReceived(_ message: LabMessage, linkID: String) {
    append("RX \(message.kind.rawValue) [\(shortID(linkID))] peer-session=\(message.session)")
  }

  mutating func appendReceiveFailure(_ failure: LabFailure, linkID: String) {
    append("Receive failed [\(shortID(linkID))]: \(failure.text)")
  }

  mutating func appendSendFailure(_ text: String, linkID: String) {
    append("Send failed [\(shortID(linkID))]: \(text)")
  }

  // MARK: - Metrics

  mutating func appendMetrics(_ metrics: LabLinkMetrics, linkID: String) {
    append("Metrics [\(shortID(linkID))] \(metrics.summary())")
  }

  mutating func appendNoPath(linkID: String) {
    append("No Wi-Fi Aware path yet [\(shortID(linkID))]")
  }

  mutating func appendMetricsFailure(_ text: String, linkID: String) {
    append("Metrics failed [\(shortID(linkID))]: \(text)")
  }

  // MARK: - Failures

  mutating func appendCannotStart(_ text: String) {
    append("Cannot start: \(text)")
  }

  mutating func appendPingSkipped(reason: String) {
    append("Ping skipped: \(reason)")
  }

  mutating func appendMetricsSkipped() {
    append("Metrics skipped: no connections")
  }

  // MARK: - Private methods

  private func shortID(_ linkID: String) -> String {
    String(linkID.prefix(8))
  }
}
