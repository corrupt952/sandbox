import Testing

@testable import wifi_aware_lab

@Suite("FetchLinkMetricsUseCase")
@MainActor
struct FetchLinkMetricsUseCaseTests {
  let repository: MockLabLinkRepository
  let sut: FetchLinkMetricsUseCase

  init() {
    repository = MockLabLinkRepository()
    sut = FetchLinkMetricsUseCase(repository: repository)
  }

  @Test func execute_WithPath_ReturnsMetricsForAccessCategory() async throws {
    repository.metricsToReturn = LabLinkMetrics(
      signalStrength: -40,
      throughputCapacity: 120,
      transmitLatency: .milliseconds(3),
      deviceName: "Peer"
    )

    let metrics = try await sut.execute(linkID: "link-1", accessCategory: .interactiveVoice)

    #expect(metrics?.deviceName == "Peer")
    #expect(repository.metricsAccessCategory == .interactiveVoice)
    #expect(repository.metricsLinkID == "link-1")
  }

  @Test func execute_WithoutPath_ReturnsNil() async throws {
    let metrics = try await sut.execute(linkID: "link-1", accessCategory: .interactiveVideo)

    #expect(metrics == nil)
  }

  @Test func execute_WhenRepositoryFails_Throws() async {
    repository.shouldThrowError = true

    await #expect(throws: TestError.generic) {
      try await sut.execute(linkID: "link-1", accessCategory: .interactiveVideo)
    }
  }
}
