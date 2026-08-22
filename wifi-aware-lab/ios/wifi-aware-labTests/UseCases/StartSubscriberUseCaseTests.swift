import Testing

@testable import wifi_aware_lab

@Suite("StartSubscriberUseCase")
@MainActor
struct StartSubscriberUseCaseTests {
  let linkRepository: MockLabLinkRepository
  let capabilityRepository: MockWiFiAwareCapabilityRepository
  let sut: StartSubscriberUseCase

  init() {
    linkRepository = MockLabLinkRepository()
    capabilityRepository = MockWiFiAwareCapabilityRepository()
    sut = StartSubscriberUseCase(
      linkRepository: linkRepository,
      capabilityRepository: capabilityRepository
    )
  }

  @Test func execute_WhenReady_StartsSubscriberWithSettings() throws {
    var settings = LabRadioSettings.default
    settings.activeDuration = .tenSeconds

    try sut.execute(settings: settings)

    #expect(linkRepository.startSubscriberCalled)
    #expect(linkRepository.startSubscriberSettings?.activeDuration == .tenSeconds)
  }

  @Test func execute_WhenAlreadyBrowsing_ThrowsSubscriberAlreadyRunning() {
    linkRepository.isBrowsing = true

    #expect(throws: LabError.subscriberAlreadyRunning) {
      try sut.execute(settings: .default)
    }
    #expect(!linkRepository.startSubscriberCalled)
  }

  @Test func execute_WhenWiFiAwareUnsupported_ThrowsUnsupported() {
    capabilityRepository.capabilities = .unsupported

    #expect(throws: LabError.unsupported) {
      try sut.execute(settings: .default)
    }
    #expect(!linkRepository.startSubscriberCalled)
  }
}
