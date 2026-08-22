import Testing

@testable import wifi_aware_lab

@Suite("FetchLabEnvironmentUseCase")
struct FetchLabEnvironmentUseCaseTests {
  @Test func execute_ReportsServiceAndCapabilities() {
    let repository = MockWiFiAwareCapabilityRepository()
    repository.serviceName = "_test._udp"
    repository.isServiceDeclared = false
    let sut = FetchLabEnvironmentUseCase(repository: repository)

    let environment = sut.execute()

    #expect(environment.serviceName == "_test._udp")
    #expect(!environment.isServiceDeclared)
    #expect(environment.capabilities.maximumConnectableDevices == 8)
  }
}
