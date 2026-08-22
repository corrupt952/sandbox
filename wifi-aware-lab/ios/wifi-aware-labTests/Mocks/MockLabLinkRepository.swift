import Foundation

@testable import wifi_aware_lab

@MainActor
final class MockLabLinkRepository: LabLinkRepositoryProtocol {
  // MARK: - Call tracking

  var startPublisherCalled = false
  var startPublisherSettings: LabRadioSettings?
  var stopPublisherCalled = false
  var startSubscriberCalled = false
  var startSubscriberSettings: LabRadioSettings?
  var stopSubscriberCalled = false
  var connectCalled = false
  var connectedEndpoint: (any LabEndpointProtocol)?
  var connectedDirection: LabLink.Direction?
  var connectedSettings: LabRadioSettings?
  var sentMessages: [(message: LabMessage, linkID: String)] = []
  var metricsCalled = false
  var metricsLinkID: String?
  var metricsAccessCategory: LabAccessCategory?

  // MARK: - Return value control

  var isPublishing = false
  var isBrowsing = false
  var activeLinkIDs: [String] = []
  var connectedDeviceIDs: Set<LabDevice.ID> = []
  var metricsToReturn: LabLinkMetrics?

  // MARK: - Error control

  var shouldThrowError = false
  var errorToThrow: any Error = TestError.generic

  // MARK: - Properties

  let events: AsyncStream<LabEvent>

  private let continuation: AsyncStream<LabEvent>.Continuation

  // MARK: - Initialization

  init() {
    let stream = AsyncStream<LabEvent>.makeStream()
    events = stream.stream
    continuation = stream.continuation
  }

  // MARK: - Protocol implementation

  func startPublisher(settings: LabRadioSettings) {
    startPublisherCalled = true
    startPublisherSettings = settings
  }

  func stopPublisher() {
    stopPublisherCalled = true
  }

  func startSubscriber(settings: LabRadioSettings) {
    startSubscriberCalled = true
    startSubscriberSettings = settings
  }

  func stopSubscriber() {
    stopSubscriberCalled = true
  }

  func connect(
    to endpoint: any LabEndpointProtocol,
    direction: LabLink.Direction,
    settings: LabRadioSettings
  ) throws {
    connectCalled = true
    connectedEndpoint = endpoint
    connectedDirection = direction
    connectedSettings = settings

    if shouldThrowError {
      throw errorToThrow
    }
  }

  func send(_ message: LabMessage, linkID: String) async throws {
    if shouldThrowError {
      throw errorToThrow
    }

    sentMessages.append((message, linkID))
  }

  func metrics(linkID: String, accessCategory: LabAccessCategory) async throws -> LabLinkMetrics? {
    metricsCalled = true
    metricsLinkID = linkID
    metricsAccessCategory = accessCategory

    if shouldThrowError {
      throw errorToThrow
    }

    return metricsToReturn
  }

  // MARK: - Public methods

  func emit(_ event: LabEvent) {
    continuation.yield(event)
  }
}
