import Foundation

protocol FetchLabEnvironmentUseCaseProtocol {
  func execute() -> LabEnvironment
}

final class FetchLabEnvironmentUseCase: FetchLabEnvironmentUseCaseProtocol {
  // MARK: - Properties

  private let repository: WiFiAwareCapabilityRepositoryProtocol

  // MARK: - Initialization

  convenience init() {
    self.init(repository: WiFiAwareCapabilityRepository.shared)
  }

  init(repository: WiFiAwareCapabilityRepositoryProtocol) {
    self.repository = repository
  }

  // MARK: - Public methods

  func execute() -> LabEnvironment {
    LabEnvironment(
      serviceName: repository.serviceName,
      isServiceDeclared: repository.isServiceDeclared,
      capabilities: repository.capabilities
    )
  }
}
