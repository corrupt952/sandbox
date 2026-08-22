import Foundation

nonisolated struct LabMessage: Codable, Sendable {
  // MARK: - Nested types

  enum Kind: String, Codable, Sendable {
    case hello
    case ping
    case pong
  }

  // MARK: - Static properties

  static let currentVersion = 1

  /// Marks a ping the heartbeat sent, so the log can stay readable while it runs.
  static let heartbeatPayload = "heartbeat"
  static let manualPingPayload = "wifi-aware-lab"

  // MARK: - Properties

  let version: Int
  let id: UUID
  let session: String
  let kind: Kind
  let sentAt: Date
  let replyTo: UUID?
  let payload: String?

  var isHeartbeat: Bool {
    payload == Self.heartbeatPayload
  }

  // MARK: - Initialization

  init(
    kind: Kind,
    session: String,
    replyTo: UUID? = nil,
    payload: String? = nil,
    identifier: UUID = UUID(),
    sentAt: Date = Date()
  ) {
    version = Self.currentVersion
    id = identifier
    self.session = session
    self.kind = kind
    self.sentAt = sentAt
    self.replyTo = replyTo
    self.payload = payload
  }
}
