import Foundation

@testable import wifi_aware_lab

final class MockPairedDeviceRepository: PairedDeviceRepositoryProtocol {
  // MARK: - Call tracking

  var devicesCalled = false

  // MARK: - Return value control

  var batchesToReturn: [[LabDevice]] = []

  // MARK: - Error control

  var errorToThrow: (any Error)?

  // MARK: - Protocol implementation

  func devices() -> AsyncThrowingStream<[LabDevice], any Error> {
    devicesCalled = true

    let batches = batchesToReturn
    let error = errorToThrow
    return AsyncThrowingStream { continuation in
      for batch in batches {
        continuation.yield(batch)
      }
      if let error {
        continuation.finish(throwing: error)
      } else {
        continuation.finish()
      }
    }
  }
}
