import Foundation

nonisolated struct LabRadioSettings: Equatable, Sendable {
  // MARK: - Static properties

  static let `default` = LabRadioSettings()

  // MARK: - Properties

  var performanceMode: LabPerformanceMode = .realtime
  var accessCategory: LabAccessCategory = .interactiveVideo
  var connectionLimit: LabConnectionLimit = .unlimited
  var activeDuration: LabActiveDuration = .systemDefault
  var heartbeat: LabHeartbeat = .oneSecond

  // MARK: - Public methods

  func summary() -> String {
    "\(performanceMode.rawValue), \(accessCategory.rawValue),"
      + " limit \(connectionLimit.rawValue), active \(activeDuration.rawValue)"
  }
}

/// How often every connected link is pinged on its own.
///
/// Also the lever for the idle-timeout question: Wi-Fi Aware closes links that go quiet after a
/// few minutes, so turning this off is what reproduces that.
nonisolated enum LabHeartbeat: String, CaseIterable, Identifiable, Sendable {
  case off = "Off"
  case oneSecond = "1 s"
  case fiveSeconds = "5 s"
  case thirtySeconds = "30 s"

  var id: Self { self }

  var interval: Duration? {
    switch self {
    case .off: nil
    case .oneSecond: .seconds(1)
    case .fiveSeconds: .seconds(5)
    case .thirtySeconds: .seconds(30)
    }
  }
}

nonisolated enum LabPerformanceMode: String, CaseIterable, Identifiable, Sendable {
  case realtime
  case bulk

  var id: Self { self }
}

nonisolated enum LabAccessCategory: String, CaseIterable, Identifiable, Sendable {
  case bestEffort = "Best effort"
  case interactiveVideo = "Video"
  case interactiveVoice = "Voice"
  case background = "Background"

  var id: Self { self }
}

/// How many incoming connections a publisher accepts.
///
/// A small value reproduces the peer limit without gathering that many devices.
nonisolated enum LabConnectionLimit: String, CaseIterable, Identifiable, Sendable {
  case unlimited = "Unlimited"
  case one = "1"
  case two = "2"
  case three = "3"

  var id: Self { self }

  /// `nil` means no limit.
  var count: Int? {
    switch self {
    case .unlimited: nil
    case .one: 1
    case .two: 2
    case .three: 3
    }
  }
}

/// How long publishing and browsing are requested to stay active.
nonisolated enum LabActiveDuration: String, CaseIterable, Identifiable, Sendable {
  case systemDefault = "Default"
  case tenSeconds = "10 s"
  case thirtySeconds = "30 s"

  var id: Self { self }

  /// `nil` leaves the duration to the system.
  var duration: Duration? {
    switch self {
    case .systemDefault: nil
    case .tenSeconds: .seconds(10)
    case .thirtySeconds: .seconds(30)
    }
  }
}
