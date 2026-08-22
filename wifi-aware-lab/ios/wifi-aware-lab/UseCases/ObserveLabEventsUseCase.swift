import Foundation

protocol ObserveLabEventsUseCaseProtocol {
  func execute() -> AsyncStream<LabEvent>
}

final class ObserveLabEventsUseCase: ObserveLabEventsUseCaseProtocol {
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

  func execute() -> AsyncStream<LabEvent> {
    repository.events
  }
}
