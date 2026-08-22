import Foundation

/// A connectable peer, kept opaque so that no layer above the repository names a Wi-Fi Aware type.
nonisolated protocol LabEndpointProtocol: Sendable {
  var deviceID: LabDevice.ID { get }
  var displayName: String { get }
}
