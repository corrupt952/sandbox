import Foundation

protocol StopSubscriberUseCaseProtocol {
  /// Returns false when no browser was running.
  @discardableResult
  func execute() -> Bool
}

final class StopSubscriberUseCase: StopSubscriberUseCaseProtocol {
  // MARK: - Properties

  private let repository: LabLinkRepositoryProtocol

  // MARK: - Initialization

  convenience init() {
    self.init(repository: LabLinkRepository.shared)
  }

  init(repository: LabLinkRepositoryProtocol) {
    self.repository = repository
  }

  // MARK: - Public methods

  @discardableResult
  func execute() -> Bool {
    guard repository.isBrowsing else { return false }

    repository.stopSubscriber()
    return true
  }
}
