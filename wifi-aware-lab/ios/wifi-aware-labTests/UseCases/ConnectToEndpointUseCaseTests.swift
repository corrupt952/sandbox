import Testing

@testable import wifi_aware_lab

@Suite("ConnectToEndpointUseCase")
@MainActor
struct ConnectToEndpointUseCaseTests {
  let linkRepository: MockLabLinkRepository
  let capabilityRepository: MockWiFiAwareCapabilityRepository
  let sut: ConnectToEndpointUseCase

  init() {
    linkRepository = MockLabLinkRepository()
    capabilityRepository = MockWiFiAwareCapabilityRepository()
    sut = ConnectToEndpointUseCase(
      linkRepository: linkRepository,
      capabilityRepository: capabilityRepository
    )
  }

  @Test func execute_WithNewDevice_ConnectsAndReturnsTrue() throws {
    let endpoint = StubLabEndpoint(deviceID: 7, displayName: "Peer")

    let didConnect = try sut.execute(
      endpoint: endpoint,
      direction: .outgoingPicker,
      settings: .default
    )

    #expect(didConnect)
    #expect(linkRepository.connectCalled)
    #expect(linkRepository.connectedDirection == .outgoingPicker)
    #expect(linkRepository.connectedEndpoint?.deviceID == 7)
  }

  @Test func execute_WhenDeviceAlreadyConnected_ReturnsFalse() throws {
    linkRepository.connectedDeviceIDs = [7]

    let didConnect = try sut.execute(
      endpoint: StubLabEndpoint(deviceID: 7, displayName: "Peer"),
      direction: .outgoingBrowse,
      settings: .default
    )

    #expect(!didConnect)
    #expect(!linkRepository.connectCalled)
  }

  @Test func execute_WhenWiFiAwareUnsupported_ThrowsUnsupported() {
    capabilityRepository.capabilities = .unsupported

    #expect(throws: LabError.unsupported) {
      try sut.execute(
        endpoint: StubLabEndpoint(),
        direction: .outgoingBrowse,
        settings: .default
      )
    }
    #expect(!linkRepository.connectCalled)
  }
}
