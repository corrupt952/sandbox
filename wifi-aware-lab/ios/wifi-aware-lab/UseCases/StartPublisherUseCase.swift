import Foundation

protocol StartPublisherUseCaseProtocol {
  func execute(settings: LabRadioSettings) throws
}

final class StartPublisherUseCase: StartPublisherUseCaseProtocol {
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

  func execute(settings: LabRadioSettings) throws {
    guard !linkRepository.isPublishing else { throw LabError.publisherAlreadyRunning }
    try LabReadiness.validate(capabilityRepository)

    linkRepository.startPublisher(settings: settings)
  }
}
