import Network
import WiFiAware

extension LabPerformanceMode {
  var wifiAwareMode: WAPerformanceMode {
    switch self {
    case .realtime: .realtime
    case .bulk: .bulk
    }
  }
}

extension LabAccessCategory {
  var wifiAwareCategory: WAAccessCategory {
    switch self {
    case .bestEffort: .bestEffort
    case .interactiveVideo: .interactiveVideo
    case .interactiveVoice: .interactiveVoice
    case .background: .background
    }
  }

  var serviceClass: NWParameters.ServiceClass {
    switch self {
    case .bestEffort: .bestEffort
    case .interactiveVideo: .interactiveVideo
    case .interactiveVoice: .interactiveVoice
    case .background: .background
    }
  }
}

extension LabConnectionLimit {
  var newConnectionLimit: Int {
    count ?? NWListener.InfiniteConnectionLimit
  }
}
