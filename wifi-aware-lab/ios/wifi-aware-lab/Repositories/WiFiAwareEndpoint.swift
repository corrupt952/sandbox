import WiFiAware

struct WiFiAwareEndpoint: LabEndpointProtocol {
  // MARK: - Properties

  let endpoint: WAEndpoint

  var deviceID: LabDevice.ID {
    endpoint.device.id
  }

  var displayName: String {
    LabDevice(endpoint.device).displayName
  }
}
