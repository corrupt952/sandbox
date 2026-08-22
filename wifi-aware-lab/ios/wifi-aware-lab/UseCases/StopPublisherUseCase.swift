import Foundation

protocol StopPublisherUseCaseProtocol {
  /// Returns false when no publisher was running.
  @discardableResult
  func execute() -> Bool
}

final class StopPublisherUseCase: StopPublisherUseCaseProtocol {
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
    guard repository.isPublishing else { return false }

    repository.stopPublisher()
    return true
  }
}
