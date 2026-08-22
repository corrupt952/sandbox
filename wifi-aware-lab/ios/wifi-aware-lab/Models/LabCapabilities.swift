import Foundation

/// The per-app limits the system reports for Wi-Fi Aware.
///
/// Apple documents no numeric value for any of these, so they are only knowable at runtime on a
/// device.
nonisolated struct LabCapabilities: Equatable, Sendable {
  // MARK: - Static properties

  static let unsupported = LabCapabilities(
    isSupported: false,
    maximumConnectableDevices: 0,
    maximumPublishableServices: 0,
    maximumSubscribableServices: 0
  )

  // MARK: - Properties

  let isSupported: Bool
  let maximumConnectableDevices: Int
  let maximumPublishableServices: Int
  let maximumSubscribableServices: Int

  // MARK: - Public methods

  func summary() -> String {
    "Peers \(maximumConnectableDevices) · Publish \(maximumPublishableServices)"
      + " · Subscribe \(maximumSubscribableServices)"
  }
}
