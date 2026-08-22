import Foundation

protocol ConnectToEndpointUseCaseProtocol {
  /// Returns false when a link to that device already exists.
  @discardableResult
  func execute(
    endpoint: any LabEndpointProtocol,
    direction: LabLink.Direction,
    settings: LabRadioSettings
  ) throws -> Bool
}

final class ConnectToEndpointUseCase: ConnectToEndpointUseCaseProtocol {
  // MARK: - Properties

  private let linkRepository: LabLinkRepositoryProtocol
  private let capabilityRepository: WiFiAwareCapabilityRepositoryProtocol

  // MARK: - Initialization

  convenience init() {
    self.init(
      linkRepository: LabLinkRepository.shared,
      capabilityRepository: WiFiAwareCapabilityRepository.shared
    )
  }

  init(
    linkRepository: LabLinkRepositoryProtocol,
    capabilityRepository: WiFiAwareCapabilityRepositoryProtocol
  ) {
    self.linkRepository = linkRepository
    self.capabilityRepository = capabilityRepository
  }

  // MARK: - Public methods

  @discardableResult
  func execute(
    endpoint: any LabEndpointProtocol,
    direction: LabLink.Direction,
    settings: LabRadioSettings
  ) throws -> Bool {
    guard !linkRepository.connectedDeviceIDs.contains(endpoint.deviceID) else { return false }
    try LabReadiness.validate(capabilityRepository)

    try linkRepository.connect(to: endpoint, direction: direction, settings: settings)
    return true
  }
}
