import Foundation

protocol WiFiAwareCapabilityRepositoryProtocol {
  var serviceName: String { get }
  var isServiceDeclared: Bool { get }
  var capabilities: LabCapabilities { get }
}
