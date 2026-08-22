import Foundation

protocol StartSubscriberUseCaseProtocol {
  func execute(settings: LabRadioSettings) throws
}

final class StartSubscriberUseCase: StartSubscriberUseCaseProtocol {
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
    guard !linkRepository.isBrowsing else { throw LabError.subscriberAlreadyRunning }
    try LabReadiness.validate(capabilityRepository)

    linkRepository.startSubscriber(settings: settings)
  }
}
