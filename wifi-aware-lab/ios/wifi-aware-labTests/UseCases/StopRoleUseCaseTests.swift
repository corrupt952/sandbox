import Testing

@testable import wifi_aware_lab

@Suite("Stopping a role")
@MainActor
struct StopRoleUseCaseTests {
  let repository = MockLabLinkRepository()

  @Test func execute_WhenPublishing_StopsPublisherAndReturnsTrue() {
    repository.isPublishing = true
    let sut = StopPublisherUseCase(repository: repository)

    let didStop = sut.execute()

    #expect(didStop)
    #expect(repository.stopPublisherCalled)
  }

  @Test func execute_WhenNotPublishing_ReturnsFalse() {
    let sut = StopPublisherUseCase(repository: repository)

    let didStop = sut.execute()

    #expect(!didStop)
    #expect(!repository.stopPublisherCalled)
  }

  @Test func execute_WhenBrowsing_StopsSubscriberAndReturnsTrue() {
    repository.isBrowsing = true
    let sut = StopSubscriberUseCase(repository: repository)

    let didStop = sut.execute()

    #expect(didStop)
    #expect(repository.stopSubscriberCalled)
  }

  @Test func execute_WhenNotBrowsing_ReturnsFalse() {
    let sut = StopSubscriberUseCase(repository: repository)

    let didStop = sut.execute()

    #expect(!didStop)
    #expect(!repository.stopSubscriberCalled)
  }
}
