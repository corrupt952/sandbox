import Testing

@testable import wifi_aware_lab

@Suite("ObservePairedDevicesUseCase")
struct ObservePairedDevicesUseCaseTests {
  let repository: MockPairedDeviceRepository
  let sut: ObservePairedDevicesUseCase

  init() {
    repository = MockPairedDeviceRepository()
    sut = ObservePairedDevicesUseCase(repository: repository)
  }

  @Test func execute_SortsEachBatchByDeviceID() async throws {
    repository.batchesToReturn = [
      [
        LabDevice(id: 9, name: nil, vendorName: nil, modelName: nil),
        LabDevice(id: 2, name: nil, vendorName: nil, modelName: nil),
        LabDevice(id: 5, name: nil, vendorName: nil, modelName: nil),
      ]
    ]

    var batches: [[LabDevice]] = []
    for try await batch in sut.execute() {
      batches.append(batch)
    }

    #expect(batches.map { $0.map(\.id) } == [[2, 5, 9]])
  }

  @Test func execute_WhenRepositoryFails_PropagatesError() async {
    repository.errorToThrow = TestError.generic

    await #expect(throws: TestError.generic) {
      for try await _ in sut.execute() {
        // Draining the stream is what surfaces the error.
      }
    }
  }
}
