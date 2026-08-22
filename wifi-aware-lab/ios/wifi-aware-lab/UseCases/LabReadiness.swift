import Foundation

/// The check every start path shares: the radio has to report support and the service has to be
/// declared, or nothing below will do anything.
enum LabReadiness {
  static func validate(_ repository: WiFiAwareCapabilityRepositoryProtocol) throws {
    guard repository.capabilities.isSupported else { throw LabError.unsupported }
    guard repository.isServiceDeclared else { throw LabError.serviceNotDeclared }
  }
}
