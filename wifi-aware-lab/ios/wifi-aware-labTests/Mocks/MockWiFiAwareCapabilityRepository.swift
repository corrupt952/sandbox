import Foundation

@testable import wifi_aware_lab

final class MockWiFiAwareCapabilityRepository: WiFiAwareCapabilityRepositoryProtocol {
  // MARK: - Return value control

  var serviceName = "_aware-lab._udp"
  var isServiceDeclared = true
  var capabilities = LabCapabilities(
    isSupported: true,
    maximumConnectableDevices: 8,
    maximumPublishableServices: 1,
    maximumSubscribableServices: 1
  )
}
