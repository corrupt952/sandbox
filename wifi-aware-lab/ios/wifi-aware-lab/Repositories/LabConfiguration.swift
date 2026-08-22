import WiFiAware

enum LabConfiguration {
  // MARK: - Static properties

  static let serviceName = "_aware-lab._udp"

  static var isServiceDeclared: Bool {
    WAPublishableService.allServices[serviceName] != nil
      && WASubscribableService.allServices[serviceName] != nil
  }

  static var publishableService: WAPublishableService {
    guard let service = WAPublishableService.allServices[serviceName] else {
      preconditionFailure("Wi-Fi Aware publishable service is missing from Info.plist")
    }
    return service
  }

  static var subscribableService: WASubscribableService {
    guard let service = WASubscribableService.allServices[serviceName] else {
      preconditionFailure("Wi-Fi Aware subscribable service is missing from Info.plist")
    }
    return service
  }
}
