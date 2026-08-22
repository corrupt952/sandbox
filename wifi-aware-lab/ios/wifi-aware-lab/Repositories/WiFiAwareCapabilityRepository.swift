import Foundation
import WiFiAware

final class WiFiAwareCapabilityRepository: WiFiAwareCapabilityRepositoryProtocol {
  // MARK: - Static properties

  static let shared = WiFiAwareCapabilityRepository()

  // MARK: - Properties

  var serviceName: String {
    LabConfiguration.serviceName
  }

  var isServiceDeclared: Bool {
    LabConfiguration.isServiceDeclared
  }

  var capabilities: LabCapabilities {
    LabCapabilities(
      isSupported: WACapabilities.supportedFeatures.contains(.wifiAware),
      maximumConnectableDevices: WACapabilities.maximumConnectableDevices,
      maximumPublishableServices: WACapabilities.maximumPublishableServices,
      maximumSubscribableServices: WACapabilities.maximumSubscribableServices
    )
  }
}
