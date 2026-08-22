import Foundation

@testable import wifi_aware_lab

struct StubLabEndpoint: LabEndpointProtocol {
  var deviceID: LabDevice.ID = 1
  var displayName = "Stub device"
}
