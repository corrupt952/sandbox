import Foundation

struct LabMessage: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case hello
        case ping
        case pong
    }

    let version: Int
    let id: UUID
    let session: String
    let kind: Kind
    let sentAt: Date
    let replyTo: UUID?
    let payload: String?

    init(
        kind: Kind,
        session: String,
        replyTo: UUID? = nil,
        payload: String? = nil
    ) {
        self.version = 1
        self.id = UUID()
        self.session = session
        self.kind = kind
        self.sentAt = Date()
        self.replyTo = replyTo
        self.payload = payload
    }
}
