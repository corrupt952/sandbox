import Foundation

protocol FetchLinkMetricsUseCaseProtocol {
  /// Returns nil while the link has no Wi-Fi Aware path yet.
  func execute(linkID: String, accessCategory: LabAccessCategory) async throws -> LabLinkMetrics?
}

final class FetchLinkMetricsUseCase: FetchLinkMetricsUseCaseProtocol {
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

  func execute(linkID: String, accessCategory: LabAccessCategory) async throws -> LabLinkMetrics? {
    try await repository.metrics(linkID: linkID, accessCategory: accessCategory)
  }
}
