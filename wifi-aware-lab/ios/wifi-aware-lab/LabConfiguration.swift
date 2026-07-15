import Network
import WiFiAware

enum LabConfiguration {
    static let serviceName = "_aware-lab._udp"

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

enum LabPerformanceMode: String, CaseIterable, Identifiable, Sendable {
    case realtime
    case bulk

    var id: Self { self }

    var value: WAPerformanceMode {
        switch self {
        case .realtime: .realtime
        case .bulk: .bulk
        }
    }
}

enum LabAccessCategory: String, CaseIterable, Identifiable, Sendable {
    case bestEffort = "Best effort"
    case interactiveVideo = "Video"
    case interactiveVoice = "Voice"
    case background = "Background"

    var id: Self { self }

    var value: WAAccessCategory {
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

extension WAPairedDevice {
    var labDisplayName: String {
        name ?? pairingInfo?.pairingName ?? "Device \(id)"
    }

    var labDescription: String {
        guard let pairingInfo else { return "ID \(id)" }
        return "\(pairingInfo.vendorName) / \(pairingInfo.modelName) / ID \(id)"
    }
}

extension Duration {
    var labMilliseconds: Double {
        let components = self.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
