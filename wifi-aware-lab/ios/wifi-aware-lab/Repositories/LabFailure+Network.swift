import Network
import WiFiAware

extension LabFailure {
  init(_ error: any Error) {
    guard let networkError = error as? NWError else {
      self.init(category: nil, description: String(describing: error))
      return
    }
    guard let awareError = networkError.wifiAware else {
      self.init(category: nil, description: String(describing: networkError))
      return
    }
    self.init(
      category: Self.category(of: awareError),
      description: String(describing: networkError)
    )
  }

  private static func category(of error: WAError) -> String {
    switch error {
    case .error: "error"
    case .wifiAwareUnsupported: "wifiAwareUnsupported"
    case .entitlementMissing: "entitlementMissing"
    case .noRadioResources: "noRadioResources"
    case .serviceNotDeclared: "serviceNotDeclared"
    case .serviceAlreadySubscribing: "serviceAlreadySubscribing"
    case .serviceAlreadyPublishing: "serviceAlreadyPublishing"
    case .noPairedDevices: "noPairedDevices"
    case .deviceInvalid: "deviceInvalid"
    case .deviceNoLongerAvailable: "deviceNoLongerAvailable"
    case .publisherTimeout: "publisherTimeout"
    case .subscriberTimeout: "subscriberTimeout"
    case .connectionFailed: "connectionFailed"
    case .connectionIdleTimeout: "connectionIdleTimeout"
    case .connectionTerminated: "connectionTerminated"
    @unknown default: "unknown"
    }
  }
}
