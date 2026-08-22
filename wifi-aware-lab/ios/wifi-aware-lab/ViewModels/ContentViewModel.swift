import Foundation
import Observation

@MainActor
@Observable
final class ContentViewModel {
  // MARK: - Properties

  let sessionID: String

  var settings = LabRadioSettings.default {
    didSet {
      guard settings.heartbeat != oldValue.heartbeat else { return }
      restartHeartbeat()
    }
  }
  var devices: [LabDevice] = []
  var links: [LabLink] = []
  var publisherStatus: LabRole.Status = .stopped
  var subscriberStatus: LabRole.Status = .stopped

  var logs: [String] {
    log.lines
  }

  var latestLog: String? {
    log.latest
  }

  var serviceName: String {
    environment.serviceName
  }

  var capabilitySummary: String {
    environment.capabilities.summary()
  }

  var maximumPeerCount: Int {
    environment.capabilities.maximumConnectableDevices
  }

  /// The role this device is running, or `nil` when both are stopped.
  ///
  /// The two roles are exclusive here even though the framework allows both at once: a guest that
  /// also publishes makes the other guests connect to each other.
  var currentRole: LabRole? {
    if publisherStatus.isRunning { return .publisher }
    if subscriberStatus.isRunning { return .subscriber }
    return nil
  }

  /// A failure keeps showing after the role falls out of `currentRole`, so the operator sees why
  /// it stopped rather than a bare "not running".
  var currentStatus: LabRole.Status {
    if publisherStatus.isRunning || publisherStatus == .failed { return publisherStatus }
    if subscriberStatus.isRunning || subscriberStatus == .failed { return subscriberStatus }
    return .stopped
  }

  var connectedLinks: [LabLink] {
    links.filter { $0.state.isActive }
  }

  var idleDevices: [LabDevice] {
    let connectedIDs = Set(connectedLinks.compactMap(\.deviceID))
    return devices.filter { !connectedIDs.contains($0.id) }
  }

  // MARK: - Dependencies

  @ObservationIgnored
  private let environment: LabEnvironment

  @ObservationIgnored
  private let observeEventsUseCase: ObserveLabEventsUseCaseProtocol

  @ObservationIgnored
  private let observeDevicesUseCase: ObservePairedDevicesUseCaseProtocol

  @ObservationIgnored
  private let startPublisherUseCase: StartPublisherUseCaseProtocol

  @ObservationIgnored
  private let stopPublisherUseCase: StopPublisherUseCaseProtocol

  @ObservationIgnored
  private let startSubscriberUseCase: StartSubscriberUseCaseProtocol

  @ObservationIgnored
  private let stopSubscriberUseCase: StopSubscriberUseCaseProtocol

  @ObservationIgnored
  private let connectToEndpointUseCase: ConnectToEndpointUseCaseProtocol

  @ObservationIgnored
  private let exchangeMessagesUseCase: ExchangeLabMessagesUseCaseProtocol

  @ObservationIgnored
  private let fetchLinkMetricsUseCase: FetchLinkMetricsUseCaseProtocol

  // MARK: - Private properties

  private var log: LabEventLog

  @ObservationIgnored
  private var eventsTask: Task<Void, Never>?

  @ObservationIgnored
  private var devicesTask: Task<Void, Never>?

  @ObservationIgnored
  private var heartbeatTask: Task<Void, Never>?

  @ObservationIgnored
  private var hasStarted = false

  private var activeLinkIDs: [String] {
    connectedLinks.map(\.id)
  }

  // MARK: - Initialization

  convenience init() {
    self.init(
      fetchEnvironmentUseCase: FetchLabEnvironmentUseCase(),
      observeEventsUseCase: ObserveLabEventsUseCase(),
      observeDevicesUseCase: ObservePairedDevicesUseCase(),
      startPublisherUseCase: StartPublisherUseCase(),
      stopPublisherUseCase: StopPublisherUseCase(),
      startSubscriberUseCase: StartSubscriberUseCase(),
      stopSubscriberUseCase: StopSubscriberUseCase(),
      connectToEndpointUseCase: ConnectToEndpointUseCase(),
      exchangeMessagesUseCase: ExchangeLabMessagesUseCase(),
      fetchLinkMetricsUseCase: FetchLinkMetricsUseCase()
    )
  }

  init(
    fetchEnvironmentUseCase: FetchLabEnvironmentUseCaseProtocol,
    observeEventsUseCase: ObserveLabEventsUseCaseProtocol,
    observeDevicesUseCase: ObservePairedDevicesUseCaseProtocol,
    startPublisherUseCase: StartPublisherUseCaseProtocol,
    stopPublisherUseCase: StopPublisherUseCaseProtocol,
    startSubscriberUseCase: StartSubscriberUseCaseProtocol,
    stopSubscriberUseCase: StopSubscriberUseCaseProtocol,
    connectToEndpointUseCase: ConnectToEndpointUseCaseProtocol,
    exchangeMessagesUseCase: ExchangeLabMessagesUseCaseProtocol,
    fetchLinkMetricsUseCase: FetchLinkMetricsUseCaseProtocol,
    dateGenerator: @escaping () -> Date = Date.init,
    uuidGenerator: @escaping () -> UUID = UUID.init
  ) {
    environment = fetchEnvironmentUseCase.execute()
    self.observeEventsUseCase = observeEventsUseCase
    self.observeDevicesUseCase = observeDevicesUseCase
    self.startPublisherUseCase = startPublisherUseCase
    self.stopPublisherUseCase = stopPublisherUseCase
    self.startSubscriberUseCase = startSubscriberUseCase
    self.stopSubscriberUseCase = stopSubscriberUseCase
    self.connectToEndpointUseCase = connectToEndpointUseCase
    self.exchangeMessagesUseCase = exchangeMessagesUseCase
    self.fetchLinkMetricsUseCase = fetchLinkMetricsUseCase
    log = LabEventLog(dateGenerator: dateGenerator)
    sessionID = String(uuidGenerator().uuidString.prefix(8)).uppercased()
  }

  // MARK: - Public methods

  func start() {
    guard !hasStarted else { return }
    hasStarted = true

    log.appendSessionStart(
      id: sessionID,
      isSupported: environment.capabilities.isSupported,
      environment: environment
    )
    observeEvents()
    observeDevices()
    restartHeartbeat()
  }

  func selectRole(_ role: LabRole?) {
    guard role != currentRole else { return }

    switch role {
    case .publisher:
      stopSubscriber()
      startPublisher()
    case .subscriber:
      stopPublisher()
      startSubscriber()
    case nil:
      stopPublisher()
      stopSubscriber()
    }
  }

  func sendPing(to linkID: String) {
    Task { [weak self] in
      guard let self else { return }
      do {
        try await exchangeMessagesUseCase.sendPing(linkID: linkID, session: sessionID)
      } catch LabError.linkNotActive(let id) {
        log.appendPingSkipped(reason: "connection \(id) is not active")
      } catch {
        log.appendSendFailure(failureText(error), linkID: linkID)
      }
    }
  }

  func sendPingToAll() {
    let linkIDs = activeLinkIDs
    guard !linkIDs.isEmpty else {
      log.appendPingSkipped(reason: "no connections")
      return
    }

    for linkID in linkIDs {
      sendPing(to: linkID)
    }
  }

  func refreshMetrics() {
    let linkIDs = activeLinkIDs
    guard !linkIDs.isEmpty else {
      log.appendMetricsSkipped()
      return
    }

    for linkID in linkIDs {
      Task { [weak self] in
        await self?.updateMetrics(for: linkID)
      }
    }
  }

  func didSelectEndpoint(_ endpoint: any LabEndpointProtocol) {
    log.appendEndpointSelected(endpoint.displayName)
    connect(to: endpoint, direction: .outgoingPicker)
  }

  func didTapAdvertiseButton() {
    log.appendAdvertiserOpened()
  }

  func didTapPickerButton() {
    log.appendPickerOpened()
  }

  func clearLogs() {
    log.clear()
  }

  // MARK: - Private methods

  private func startPublisher() {
    do {
      try startPublisherUseCase.execute(settings: settings)
      log.appendRoleRequested(.publisher, settings: settings)
    } catch LabError.publisherAlreadyRunning {
      log.appendRoleAlreadyRunning(.publisher)
    } catch {
      log.appendCannotStart(failureText(error))
    }
  }

  private func stopPublisher() {
    guard stopPublisherUseCase.execute() else { return }

    log.appendRoleStopping(.publisher)
    publisherStatus = .stopped
  }

  private func startSubscriber() {
    do {
      try startSubscriberUseCase.execute(settings: settings)
      log.appendRoleRequested(.subscriber, settings: settings)
    } catch LabError.subscriberAlreadyRunning {
      log.appendRoleAlreadyRunning(.subscriber)
    } catch {
      log.appendCannotStart(failureText(error))
    }
  }

  private func stopSubscriber() {
    guard stopSubscriberUseCase.execute() else { return }

    log.appendRoleStopping(.subscriber)
    subscriberStatus = .stopped
  }

  /// Pings every link on a timer so the trend keeps moving without anyone tapping.
  ///
  /// Heartbeat pings are silent: logging one line per link per second would bury everything else
  /// in the log, and the round trip already lands in the link's history.
  private func restartHeartbeat() {
    heartbeatTask?.cancel()
    heartbeatTask = nil

    guard let interval = settings.heartbeat.interval else { return }

    heartbeatTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: interval)
        guard let self, !Task.isCancelled else { return }

        for linkID in activeLinkIDs {
          try? await exchangeMessagesUseCase.sendPing(
            linkID: linkID,
            session: sessionID,
            isHeartbeat: true
          )
        }
      }
    }
  }

  private func observeEvents() {
    eventsTask = Task { [weak self] in
      guard let self else { return }
      for await event in observeEventsUseCase.execute() {
        apply(event)
      }
    }
  }

  private func observeDevices() {
    devicesTask = Task { [weak self] in
      guard let self else { return }
      do {
        for try await devices in observeDevicesUseCase.execute() {
          self.devices = devices
          log.appendPairedDeviceCount(devices.count)
        }
      } catch is CancellationError {
        return
      } catch {
        log.appendPairedDeviceFailure(error)
      }
    }
  }

  private func apply(_ event: LabEvent) {
    switch event {
    case .roleStateChanged(let role, let status, let failure):
      setStatus(status, for: role)
      log.appendRoleState(role, status: status, failure: failure)
    case .roleEnded(let role, let outcome):
      apply(outcome, for: role)
    case .endpointsDiscovered(let endpoints):
      subscriberStatus = .browsing(foundCount: endpoints.count)
      for endpoint in endpoints {
        connect(to: endpoint, direction: .outgoingBrowse)
      }
    case .linkAdded(let link, let activeCount):
      links.insert(link, at: 0)
      log.appendLinkAdded(link, activeCount: activeCount, maximum: maximumPeerCount)
    case .linkStateChanged(let linkID, let state, let local, let remote, let failure):
      apply(state, to: linkID, localEndpoint: local, remoteEndpoint: remote, failure: failure)
    case .messageSent(let message, let linkID):
      if !message.isHeartbeat {
        log.appendMessageSent(message, linkID: linkID)
      }
    case .messageReceived(let message, let linkID):
      if !message.isHeartbeat {
        log.appendMessageReceived(message, linkID: linkID)
      }
      receive(message, linkID: linkID)
    case .receiveFailed(let linkID, let failure):
      log.appendReceiveFailure(failure, linkID: linkID)
    }
  }

  private func apply(_ outcome: LabRole.Outcome, for role: LabRole) {
    switch outcome {
    case .cancelled, .finished:
      setStatus(.stopped, for: role)
    case .failed:
      setStatus(.failed, for: role)
    }
    log.appendRoleOutcome(outcome, for: role)
  }

  private func apply(
    _ state: LabLink.State,
    to linkID: String,
    localEndpoint: String?,
    remoteEndpoint: String?,
    failure: LabFailure?
  ) {
    log.appendLinkState(linkID, state: state, failure: failure)
    updateLink(linkID) { link in
      link.state = state
      link.localEndpoint = localEndpoint
      link.remoteEndpoint = remoteEndpoint
    }

    guard state == .ready else { return }
    Task { [weak self] in
      await self?.linkDidBecomeReady(linkID)
    }
  }

  private func linkDidBecomeReady(_ linkID: String) async {
    await updateMetrics(for: linkID)
    do {
      try await exchangeMessagesUseCase.sendHello(linkID: linkID, session: sessionID)
    } catch {
      log.appendSendFailure(failureText(error), linkID: linkID)
    }
  }

  private func receive(_ message: LabMessage, linkID: String) {
    Task { [weak self] in
      guard let self else { return }
      do {
        let roundTrip = try await exchangeMessagesUseCase.receive(
          message,
          linkID: linkID,
          session: sessionID
        )
        guard let roundTrip else { return }

        updateLink(linkID) { $0.record(roundTrip: roundTrip) }
        if !message.isHeartbeat {
          log.appendRoundTrip(roundTrip, linkID: linkID)
        }
      } catch {
        log.appendSendFailure(failureText(error), linkID: linkID)
      }
    }
  }

  private func updateMetrics(for linkID: String) async {
    do {
      let metrics = try await fetchLinkMetricsUseCase.execute(
        linkID: linkID,
        accessCategory: settings.accessCategory
      )
      guard let metrics else {
        log.appendNoPath(linkID: linkID)
        return
      }

      updateLink(linkID) { link in
        link.deviceName = metrics.deviceName
        link.metrics = metrics
      }
      log.appendMetrics(metrics, linkID: linkID)
    } catch {
      log.appendMetricsFailure(failureText(error), linkID: linkID)
    }
  }

  private func connect(to endpoint: any LabEndpointProtocol, direction: LabLink.Direction) {
    do {
      let didConnect = try connectToEndpointUseCase.execute(
        endpoint: endpoint,
        direction: direction,
        settings: settings
      )
      guard didConnect else { return }

      log.appendConnecting(to: endpoint.displayName)
    } catch {
      log.appendCannotStart(failureText(error))
    }
  }

  private func setStatus(_ status: LabRole.Status, for role: LabRole) {
    switch role {
    case .publisher:
      publisherStatus = status
    case .subscriber:
      subscriberStatus = status
    }
  }

  private func failureText(_ error: any Error) -> String {
    guard let error = error as? LabError else { return String(describing: error) }

    switch error {
    case .unsupported:
      return "this device does not report Wi-Fi Aware support"
    case .serviceNotDeclared:
      return "\(serviceName) is missing from Info.plist"
    case .publisherAlreadyRunning:
      return "the publisher is already active"
    case .subscriberAlreadyRunning:
      return "the subscriber browser is already active"
    case .linkNotActive(let linkID):
      return "connection \(linkID) is not active"
    case .unsupportedEndpoint:
      return "the selected endpoint is not a Wi-Fi Aware endpoint"
    case .failure(let failure):
      return failure.text
    }
  }

  private func updateLink(_ linkID: String, change: (inout LabLink) -> Void) {
    guard let index = links.firstIndex(where: { $0.id == linkID }) else { return }

    change(&links[index])
  }
}
