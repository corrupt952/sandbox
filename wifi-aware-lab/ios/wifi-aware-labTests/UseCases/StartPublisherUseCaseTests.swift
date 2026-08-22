import Testing

@testable import wifi_aware_lab

@Suite("StartPublisherUseCase")
@MainActor
struct StartPublisherUseCaseTests {
  let linkRepository: MockLabLinkRepository
  let capabilityRepository: MockWiFiAwareCapabilityRepository
  let sut: StartPublisherUseCase

  init() {
    linkRepository = MockLabLinkRepository()
    capabilityRepository = MockWiFiAwareCapabilityRepository()
    sut = StartPublisherUseCase(
      linkRepository: linkRepository,
      capabilityRepository: capabilityRepository
    )
  }

  @Test func execute_WhenReady_StartsPublisherWithSettings() throws {
    var settings = LabRadioSettings.default
    settings.connectionLimit = .two

    try sut.execute(settings: settings)

    #expect(linkRepository.startPublisherCalled)
    #expect(linkRepository.startPublisherSettings?.connectionLimit == .two)
  }

  @Test func execute_WhenAlreadyPublishing_ThrowsPublisherAlreadyRunning() {
    linkRepository.isPublishing = true

    #expect(throws: LabError.publisherAlreadyRunning) {
      try sut.execute(settings: .default)
    }
    #expect(!linkRepository.startPublisherCalled)
  }

  @Test func execute_WhenWiFiAwareUnsupported_ThrowsUnsupported() {
    capabilityRepository.capabilities = .unsupported

    #expect(throws: LabError.unsupported) {
      try sut.execute(settings: .default)
    }
    #expect(!linkRepository.startPublisherCalled)
  }

  @Test func execute_WhenServiceNotDeclared_ThrowsServiceNotDeclared() {
    capabilityRepository.isServiceDeclared = false

    #expect(throws: LabError.serviceNotDeclared) {
      try sut.execute(settings: .default)
    }
    #expect(!linkRepository.startPublisherCalled)
  }
}
