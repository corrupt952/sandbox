import Foundation

protocol ExchangeLabMessagesUseCaseProtocol {
  func sendHello(linkID: String, session: String) async throws
  func sendPing(linkID: String, session: String, isHeartbeat: Bool) async throws
  /// Returns the round trip when the message closes a ping this app sent.
  func receive(_ message: LabMessage, linkID: String, session: String) async throws -> Duration?
}

extension ExchangeLabMessagesUseCaseProtocol {
  func sendPing(linkID: String, session: String) async throws {
    try await sendPing(linkID: linkID, session: session, isHeartbeat: false)
  }
}

final class ExchangeLabMessagesUseCase: ExchangeLabMessagesUseCaseProtocol {
  // MARK: - Properties

  private let repository: LabLinkRepositoryProtocol
  private let dateGenerator: () -> Date
  private var pendingPings: [UUID: Date] = [:]

  // MARK: - Initialization

  convenience init() {
    self.init(repository: LabLinkRepository.shared)
  }

  init(repository: LabLinkRepositoryProtocol, dateGenerator: @escaping () -> Date = Date.init) {
    self.repository = repository
    self.dateGenerator = dateGenerator
  }

  // MARK: - Public methods

  func sendHello(linkID: String, session: String) async throws {
    let hello = LabMessage(kind: .hello, session: session, payload: "iOS Wi-Fi Aware Lab")
    try await repository.send(hello, linkID: linkID)
  }

  func sendPing(linkID: String, session: String, isHeartbeat: Bool) async throws {
    guard repository.activeLinkIDs.contains(linkID) else { throw LabError.linkNotActive(linkID) }

    let ping = LabMessage(
      kind: .ping,
      session: session,
      payload: isHeartbeat ? LabMessage.heartbeatPayload : LabMessage.manualPingPayload,
      sentAt: dateGenerator()
    )
    pendingPings[ping.id] = ping.sentAt
    try await repository.send(ping, linkID: linkID)
  }

  func receive(_ message: LabMessage, linkID: String, session: String) async throws -> Duration? {
    switch message.kind {
    case .hello:
      return nil
    case .ping:
      // Carry the payload back so the sender can tell a heartbeat round trip from a manual one.
      let pong = LabMessage(
        kind: .pong,
        session: session,
        replyTo: message.id,
        payload: message.payload
      )
      try await repository.send(pong, linkID: linkID)
      return nil
    case .pong:
      guard let replyTo = message.replyTo,
        let sentAt = pendingPings.removeValue(forKey: replyTo)
      else { return nil }
      return .seconds(dateGenerator().timeIntervalSince(sentAt))
    }
  }
}
