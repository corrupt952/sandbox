import Foundation
import Testing

@testable import wifi_aware_lab

@Suite("ContentViewModel")
@MainActor
struct ContentViewModelTests {
  let linkRepository: MockLabLinkRepository
  let capabilityRepository: MockWiFiAwareCapabilityRepository
  let deviceRepository: MockPairedDeviceRepository
  let sut: ContentViewModel

  init() {
    let linkRepository = MockLabLinkRepository()
    let capabilityRepository = MockWiFiAwareCapabilityRepository()
    let deviceRepository = MockPairedDeviceRepository()
    self.linkRepository = linkRepository
    self.capabilityRepository = capabilityRepository
    self.deviceRepository = deviceRepository

    sut = ContentViewModel(
      fetchEnvironmentUseCase: FetchLabEnvironmentUseCase(repository: capabilityRepository),
      observeEventsUseCase: ObserveLabEventsUseCase(repository: linkRepository),
      observeDevicesUseCase: ObservePairedDevicesUseCase(repository: deviceRepository),
      startPublisherUseCase: StartPublisherUseCase(
        linkRepository: linkRepository,
        capabilityRepository: capabilityRepository
      ),
      stopPublisherUseCase: StopPublisherUseCase(repository: linkRepository),
      startSubscriberUseCase: StartSubscriberUseCase(
        linkRepository: linkRepository,
        capabilityRepository: capabilityRepository
      ),
      stopSubscriberUseCase: StopSubscriberUseCase(repository: linkRepository),
      connectToEndpointUseCase: ConnectToEndpointUseCase(
        linkRepository: linkRepository,
        capabilityRepository: capabilityRepository
      ),
      exchangeMessagesUseCase: ExchangeLabMessagesUseCase(repository: linkRepository),
      fetchLinkMetricsUseCase: FetchLinkMetricsUseCase(repository: linkRepository),
      dateGenerator: { Date(timeIntervalSince1970: 0) }
    )
  }

  @Test func start_LogsSessionAndEnvironment() {
    sut.start()

    #expect(sut.logs.count == 3)
    #expect(sut.logs[0].hasSuffix("Session \(sut.sessionID) started"))
    #expect(sut.logs[1].hasSuffix("Wi-Fi Aware supported: true"))
    #expect(sut.logs[2].hasSuffix("Service declared: true (_aware-lab._udp)"))
  }

  @Test func start_WhenCalledTwice_LogsOnce() {
    sut.start()
    sut.start()

    #expect(sut.logs.count == 3)
  }

  @Test func selectRole_WithPublisher_StartsAndLogsSettings() {
    sut.selectRole(.publisher)

    #expect(linkRepository.startPublisherCalled)
    #expect(sut.logs.last?.hasSuffix("Publisher requested (\(sut.settings.summary()))") == true)
  }

  @Test func selectRole_WithSubscriber_StartsSubscriber() {
    sut.selectRole(.subscriber)

    #expect(linkRepository.startSubscriberCalled)
    #expect(!linkRepository.startPublisherCalled)
  }

  @Test func selectRole_WhenAlreadyPublishing_LogsAlreadyActive() {
    linkRepository.isPublishing = true

    sut.selectRole(.publisher)

    #expect(sut.logs.last?.hasSuffix("Publisher is already active") == true)
  }

  @Test func selectRole_WhenUnsupported_LogsCannotStart() {
    capabilityRepository.capabilities = .unsupported

    sut.selectRole(.publisher)

    #expect(
      sut.logs.last?.hasSuffix(
        "Cannot start: this device does not report Wi-Fi Aware support"
      ) == true
    )
    #expect(!linkRepository.startPublisherCalled)
  }

  @Test func selectRole_WithNil_WhenNothingRunning_LogsNothing() {
    sut.selectRole(nil)

    #expect(sut.logs.isEmpty)
  }

  @Test func sendPingToAll_WithoutLinks_LogsSkipped() {
    sut.sendPingToAll()

    #expect(sut.logs.last?.hasSuffix("Ping skipped: no connections") == true)
  }

  @Test func refreshMetrics_WithoutLinks_LogsSkipped() {
    sut.refreshMetrics()

    #expect(sut.logs.last?.hasSuffix("Metrics skipped: no connections") == true)
  }

  @Test func clearLogs_KeepsOnlyTheClearedEntry() {
    sut.start()

    sut.clearLogs()

    #expect(sut.logs.count == 1)
    #expect(sut.logs[0].hasSuffix("Log cleared"))
  }

  @Test func currentRole_WhenPublisherIsRunning_ReadsPublisher() {
    sut.publisherStatus = .ready

    #expect(sut.currentRole == .publisher)
    #expect(sut.currentStatus == .ready)
  }

  @Test func currentRole_WhenBothStopped_ReadsNil() {
    #expect(sut.currentRole == nil)
    #expect(sut.currentStatus == .stopped)
  }

  @Test func currentStatus_AfterFailure_KeepsTheFailureVisible() {
    sut.publisherStatus = .failed

    #expect(sut.currentRole == nil)
    #expect(sut.currentStatus == .failed)
  }

  @Test func didSelectEndpoint_ConnectsAndLogsSelection() {
    let endpoint = StubLabEndpoint(deviceID: 3, displayName: "Peer")

    sut.didSelectEndpoint(endpoint)

    #expect(linkRepository.connectCalled)
    #expect(linkRepository.connectedDirection == .outgoingPicker)
    #expect(sut.logs.first?.hasSuffix("DevicePicker selected Peer") == true)
    #expect(sut.logs.last?.hasSuffix("Discovered Peer, connecting") == true)
  }
}
