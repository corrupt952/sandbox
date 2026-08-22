import Foundation
import Testing

@testable import wifi_aware_lab

@Suite("ExchangeLabMessagesUseCase")
@MainActor
struct ExchangeLabMessagesUseCaseTests {
  /// Lets a test move the clock between sending a ping and receiving its pong.
  final class Clock {
    var now = Date(timeIntervalSince1970: 0)
  }

  let repository: MockLabLinkRepository
  let clock: Clock
  let sut: ExchangeLabMessagesUseCase

  init() {
    repository = MockLabLinkRepository()
    repository.activeLinkIDs = ["link-1"]
    let clock = Clock()
    self.clock = clock
    sut = ExchangeLabMessagesUseCase(repository: repository, dateGenerator: { clock.now })
  }

  @Test func sendHello_SendsHelloOverLink() async throws {
    try await sut.sendHello(linkID: "link-1", session: "SESSION")

    let sent = try #require(repository.sentMessages.first)
    #expect(sent.message.kind == .hello)
    #expect(sent.message.session == "SESSION")
    #expect(sent.linkID == "link-1")
  }

  @Test func sendPing_OnActiveLink_SendsPing() async throws {
    try await sut.sendPing(linkID: "link-1", session: "SESSION")

    let sent = try #require(repository.sentMessages.first)
    #expect(sent.message.kind == .ping)
    #expect(sent.linkID == "link-1")
  }

  @Test func sendPing_OnInactiveLink_ThrowsLinkNotActive() async {
    await #expect(throws: LabError.linkNotActive("link-2")) {
      try await sut.sendPing(linkID: "link-2", session: "SESSION")
    }
    #expect(repository.sentMessages.isEmpty)
  }

  @Test func receive_WithPing_RepliesWithPong() async throws {
    let ping = LabMessage(kind: .ping, session: "PEER")

    let roundTrip = try await sut.receive(ping, linkID: "link-1", session: "SESSION")

    #expect(roundTrip == nil)
    let sent = try #require(repository.sentMessages.first)
    #expect(sent.message.kind == .pong)
    #expect(sent.message.replyTo == ping.id)
  }

  @Test func receive_WithPongForOwnPing_ReturnsRoundTrip() async throws {
    try await sut.sendPing(linkID: "link-1", session: "SESSION")
    let ping = try #require(repository.sentMessages.first).message
    clock.now = Date(timeIntervalSince1970: 0.25)
    let pong = LabMessage(kind: .pong, session: "PEER", replyTo: ping.id)

    let roundTrip = try await sut.receive(pong, linkID: "link-1", session: "SESSION")

    let milliseconds = try #require(roundTrip).totalMilliseconds
    #expect(abs(milliseconds - 250) < 0.001)
  }

  @Test func receive_WithPongForUnknownPing_ReturnsNil() async throws {
    let pong = LabMessage(kind: .pong, session: "PEER", replyTo: UUID())

    let roundTrip = try await sut.receive(pong, linkID: "link-1", session: "SESSION")

    #expect(roundTrip == nil)
  }

  @Test func receive_WithHello_SendsNothing() async throws {
    let hello = LabMessage(kind: .hello, session: "PEER")

    let roundTrip = try await sut.receive(hello, linkID: "link-1", session: "SESSION")

    #expect(roundTrip == nil)
    #expect(repository.sentMessages.isEmpty)
  }
}
