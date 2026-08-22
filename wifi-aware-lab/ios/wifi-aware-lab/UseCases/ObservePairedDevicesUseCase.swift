import Foundation

protocol ObservePairedDevicesUseCaseProtocol {
  func execute() -> AsyncThrowingStream<[LabDevice], any Error>
}

final class ObservePairedDevicesUseCase: ObservePairedDevicesUseCaseProtocol {
  // MARK: - Properties

  private let repository: PairedDeviceRepositoryProtocol

  // MARK: - Initialization

  convenience init() {
    self.init(repository: PairedDeviceRepository.shared)
  }

  init(repository: PairedDeviceRepositoryProtocol) {
    self.repository = repository
  }

  // MARK: - Public methods

  func execute() -> AsyncThrowingStream<[LabDevice], any Error> {
    let devices = repository.devices()
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for try await batch in devices {
            continuation.yield(batch.sorted { $0.id < $1.id })
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
