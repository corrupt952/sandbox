import Foundation

nonisolated enum LabEvent: Sendable {
  case roleStateChanged(LabRole, LabRole.Status, failure: LabFailure?)
  case roleEnded(LabRole, LabRole.Outcome)
  case endpointsDiscovered([any LabEndpointProtocol])
  case linkAdded(LabLink, activeCount: Int)
  case linkStateChanged(
    linkID: String,
    state: LabLink.State,
    localEndpoint: String?,
    remoteEndpoint: String?,
    failure: LabFailure?
  )
  case messageSent(LabMessage, linkID: String)
  case messageReceived(LabMessage, linkID: String)
  case receiveFailed(linkID: String, failure: LabFailure)
}
