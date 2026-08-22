import Foundation

protocol PairedDeviceRepositoryProtocol {
  func devices() -> AsyncThrowingStream<[LabDevice], any Error>
}
