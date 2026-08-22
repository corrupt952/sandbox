import Foundation
import Network
import WiFiAware

@MainActor
final class LabLinkRepository: LabLinkRepositoryProtocol {
  // MARK: - Type aliases

  typealias LabProtocol = Coder<LabMessage, LabMessage, NetworkJSONCoder>
  typealias LabConnection = NetworkConnection<LabProtocol>

  // MARK: - Static properties

  static let shared = LabLinkRepository()

  // MARK: - Properties

  let events: AsyncStream<LabEvent>

  private let continuation: AsyncStream<LabEvent>.Continuation
  private var connections: [String: LabConnection] = [:]
  private var deviceIDs: [String: LabDevice.ID] = [:]
  private var receiverTasks: [String: Task<Void, Never>] = [:]
  private var listenerTask: Task<Void, Never>?
  private var browserTask: Task<Void, Never>?
  private var publisherGeneration = 0
  private var subscriberGeneration = 0

  var isPublishing: Bool {
    listenerTask != nil
  }

  var isBrowsing: Bool {
    browserTask != nil
  }

  var activeLinkIDs: [String] {
    Array(connections.keys)
  }

  var connectedDeviceIDs: Set<LabDevice.ID> {
    Set(deviceIDs.values)
  }

  // MARK: - Initialization

  init() {
    let stream = AsyncStream<LabEvent>.makeStream()
    events = stream.stream
    continuation = stream.continuation
  }

  // MARK: - Public methods

  func startPublisher(settings: LabRadioSettings) {
    guard listenerTask == nil else { return }

    let mode = settings.performanceMode.wifiAwareMode
    let serviceClass = settings.accessCategory.serviceClass
    let limit = settings.connectionLimit.newConnectionLimit
    let active = settings.activeDuration.duration
    publisherGeneration += 1
    let generation = publisherGeneration

    continuation.yield(.roleStateChanged(.publisher, .starting, failure: nil))
    listenerTask = Task { [weak self] in
      guard let self else { return }
      var outcome = LabRole.Outcome.cancelled
      defer {
        clearListenerTask(generation: generation)
        continuation.yield(.roleEnded(.publisher, outcome))
      }

      do {
        try await NetworkListener(
          for: .wifiAware(
            // `.userSpecifiedDevices` belongs to the pairing UI; a listener built with it fails.
            .connecting(to: LabConfiguration.publishableService, from: .allPairedDevices),
            active: active
          ),
          using: .parameters {
            Coder(receiving: LabMessage.self, sending: LabMessage.self, using: NetworkJSONCoder()) {
              UDP()
            }
          }
          .wifiAware { $0.performanceMode = mode }
          .serviceClass(serviceClass)
        )
        .newConnectionLimit(limit)
        .onStateUpdate { [weak self] _, state in
          self?.publisherStateDidUpdate(state)
        }
        .run { [weak self] connection in
          self?.add(connection, direction: .incoming)
        }
        outcome = .finished
      } catch is CancellationError {
        outcome = .cancelled
      } catch {
        outcome = .failed(LabFailure(error))
      }
    }
  }

  func stopPublisher() {
    listenerTask?.cancel()
    listenerTask = nil
  }

  func startSubscriber(settings: LabRadioSettings) {
    guard browserTask == nil else { return }

    let active = settings.activeDuration.duration
    subscriberGeneration += 1
    let generation = subscriberGeneration

    continuation.yield(.roleStateChanged(.subscriber, .starting, failure: nil))
    browserTask = Task { [weak self] in
      guard let self else { return }
      var outcome = LabRole.Outcome.cancelled
      defer {
        clearBrowserTask(generation: generation)
        continuation.yield(.roleEnded(.subscriber, outcome))
      }

      do {
        try await NetworkBrowser(
          for: .wifiAware(
            .connecting(to: .allPairedDevices, from: LabConfiguration.subscribableService),
            active: active
          )
        )
        .onStateUpdate { [weak self] _, state in
          self?.subscriberStateDidUpdate(state)
        }
        // The `Void` overload keeps browsing until the task is cancelled; the other overload
        // ends the browse as soon as the handler returns a result.
        .run { [weak self] (endpoints: [WAEndpoint]) -> Void in
          self?.endpointsDidUpdate(endpoints)
        }
        outcome = .finished
      } catch is CancellationError {
        outcome = .cancelled
      } catch {
        outcome = .failed(LabFailure(error))
      }
    }
  }

  func stopSubscriber() {
    browserTask?.cancel()
    browserTask = nil
  }

  func connect(
    to endpoint: any LabEndpointProtocol,
    direction: LabLink.Direction,
    settings: LabRadioSettings
  ) throws {
    guard let endpoint = endpoint as? WiFiAwareEndpoint else { throw LabError.unsupportedEndpoint }

    let mode = settings.performanceMode.wifiAwareMode
    let serviceClass = settings.accessCategory.serviceClass
    let connection = NetworkConnection(
      to: endpoint.endpoint,
      using: .parameters {
        Coder(receiving: LabMessage.self, sending: LabMessage.self, using: NetworkJSONCoder()) {
          UDP()
        }
      }
      .wifiAware { $0.performanceMode = mode }
      .serviceClass(serviceClass)
    )
    add(connection, direction: direction, deviceID: endpoint.deviceID)
  }

  func send(_ message: LabMessage, linkID: String) async throws {
    guard let connection = connections[linkID] else { throw LabError.linkNotActive(linkID) }

    do {
      try await connection.send(message)
    } catch {
      throw LabError.failure(LabFailure(error))
    }
    continuation.yield(.messageSent(message, linkID: linkID))
  }

  func metrics(linkID: String, accessCategory: LabAccessCategory) async throws -> LabLinkMetrics? {
    guard let connection = connections[linkID] else { throw LabError.linkNotActive(linkID) }

    do {
      guard let path = connection.currentPath, let awarePath = try await path.wifiAware else {
        return nil
      }

      let report = awarePath.performance
      return LabLinkMetrics(
        signalStrength: report.signalStrength,
        throughputCapacity: report.throughputCapacity,
        transmitLatency: report.transmitLatency[accessCategory.wifiAwareCategory]?.average,
        deviceName: LabDevice(awarePath.endpoint.device).displayName
      )
    } catch {
      throw LabError.failure(LabFailure(error))
    }
  }

  // MARK: - Private methods

  private func add(
    _ connection: LabConnection,
    direction: LabLink.Direction,
    deviceID: LabDevice.ID? = nil
  ) {
    guard connections[connection.id] == nil else { return }

    connections[connection.id] = connection
    if let deviceID {
      deviceIDs[connection.id] = deviceID
    }
    let link = LabLink(id: connection.id, direction: direction, state: .setup, deviceID: deviceID)
    continuation.yield(.linkAdded(link, activeCount: connections.count))

    connection.onStateUpdate { [weak self] connection, state in
      self?.connectionStateDidUpdate(connection, state: state)
    }
    receiverTasks[connection.id] = Task { [weak self] in
      do {
        for try await (message, _) in connection.messages {
          self?.continuation.yield(.messageReceived(message, linkID: connection.id))
        }
      } catch is CancellationError {
        return
      } catch {
        self?.continuation.yield(
          .receiveFailed(linkID: connection.id, failure: LabFailure(error))
        )
      }
    }
  }

  private func connectionStateDidUpdate(
    _ connection: LabConnection,
    state: LabConnection.State
  ) {
    let linkState: LabLink.State
    var failure: LabFailure?
    switch state {
    case .setup:
      linkState = .setup
    case .waiting(let error):
      linkState = .waiting
      failure = LabFailure(error)
    case .preparing:
      linkState = .preparing
    case .ready:
      linkState = .ready
    case .failed(let error):
      linkState = .failed
      failure = LabFailure(error)
    case .cancelled:
      linkState = .cancelled
    @unknown default:
      linkState = .unknown
    }

    continuation.yield(
      .linkStateChanged(
        linkID: connection.id,
        state: linkState,
        localEndpoint: connection.localEndpoint?.debugDescription,
        remoteEndpoint: connection.remoteEndpoint?.debugDescription,
        failure: failure
      )
    )

    guard !linkState.isActive else { return }
    connections.removeValue(forKey: connection.id)
    deviceIDs.removeValue(forKey: connection.id)
    receiverTasks.removeValue(forKey: connection.id)?.cancel()
  }

  private func publisherStateDidUpdate(_ state: NetworkListener<LabProtocol>.State) {
    switch state {
    case .setup:
      yieldRoleState(.publisher, .setup)
    case .waiting(let error):
      yieldRoleState(.publisher, .waiting, failure: LabFailure(error))
    case .ready:
      yieldRoleState(.publisher, .ready)
    case .failed(let error):
      yieldRoleState(.publisher, .failed, failure: LabFailure(error))
    case .cancelled:
      yieldRoleState(.publisher, .stopped)
    @unknown default:
      yieldRoleState(.publisher, .unknown)
    }
  }

  private func subscriberStateDidUpdate(_ state: NetworkBrowser<WASubscriberBrowser>.State) {
    switch state {
    case .setup:
      yieldRoleState(.subscriber, .setup)
    case .waiting(let error):
      yieldRoleState(.subscriber, .waiting, failure: LabFailure(error))
    case .ready:
      yieldRoleState(.subscriber, .ready)
    case .failed(let error):
      yieldRoleState(.subscriber, .failed, failure: LabFailure(error))
    case .cancelled:
      yieldRoleState(.subscriber, .stopped)
    @unknown default:
      yieldRoleState(.subscriber, .unknown)
    }
  }

  private func yieldRoleState(
    _ role: LabRole,
    _ status: LabRole.Status,
    failure: LabFailure? = nil
  ) {
    continuation.yield(.roleStateChanged(role, status, failure: failure))
  }

  private func endpointsDidUpdate(_ endpoints: [WAEndpoint]) {
    continuation.yield(.endpointsDiscovered(endpoints.map(WiFiAwareEndpoint.init)))
  }

  /// Clears the handle only while it still points at the run that is ending: a restart between
  /// cancellation and exit has already installed a newer task under the same property.
  private func clearListenerTask(generation: Int) {
    guard generation == publisherGeneration else { return }
    listenerTask = nil
  }

  private func clearBrowserTask(generation: Int) {
    guard generation == subscriberGeneration else { return }
    browserTask = nil
  }
}
