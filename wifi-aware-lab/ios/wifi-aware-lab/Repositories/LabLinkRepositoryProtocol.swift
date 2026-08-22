import Foundation

@MainActor
protocol LabLinkRepositoryProtocol: AnyObject {
  var events: AsyncStream<LabEvent> { get }
  var isPublishing: Bool { get }
  var isBrowsing: Bool { get }
  var activeLinkIDs: [String] { get }
  var connectedDeviceIDs: Set<LabDevice.ID> { get }

  func startPublisher(settings: LabRadioSettings)
  func stopPublisher()
  func startSubscriber(settings: LabRadioSettings)
  func stopSubscriber()
  func connect(
    to endpoint: any LabEndpointProtocol,
    direction: LabLink.Direction,
    settings: LabRadioSettings
  ) throws
  func send(_ message: LabMessage, linkID: String) async throws
  func metrics(linkID: String, accessCategory: LabAccessCategory) async throws -> LabLinkMetrics?
}
