import Foundation
import WiFiAware

final class PairedDeviceRepository: PairedDeviceRepositoryProtocol {
  // MARK: - Static properties

  static let shared = PairedDeviceRepository()

  // MARK: - Public methods

  func devices() -> AsyncThrowingStream<[LabDevice], any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for try await devices in WAPairedDevice.allDevices {
            continuation.yield(devices.values.map(LabDevice.init))
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
