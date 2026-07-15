import Foundation
import Network
import Observation
import WiFiAware

typealias LabProtocol = Coder<LabMessage, LabMessage, NetworkJSONCoder>
typealias LabConnection = NetworkConnection<LabProtocol>

struct LabConnectionRow: Identifiable, Sendable {
    let id: String
    var direction: String
    var state: String
    var device: String
    var endpoints: String
    var roundTripMilliseconds: Double?
    var performance: String?
}

@MainActor
@Observable
final class WiFiAwareLabModel {
    let sessionID = String(UUID().uuidString.prefix(8)).uppercased()

    var pairedDevices: [WAPairedDevice] = []
    var connections: [LabConnectionRow] = []
    var logs: [String] = []
    var publisherStatus = "Stopped"
    var subscriberStatus = "Stopped"
    var performanceMode: LabPerformanceMode = .realtime
    var accessCategory: LabAccessCategory = .interactiveVideo

    private var pairedDevicesTask: Task<Void, Never>?
    private var listenerTask: Task<Void, Never>?
    private var browserTask: Task<Void, Never>?
    private var receiverTasks: [String: Task<Void, Never>] = [:]
    private var activeConnections: [String: LabConnection] = [:]
    private var pendingPings: [UUID: Date] = [:]
    private var hasStarted = false

    var isWiFiAwareSupported: Bool {
        WACapabilities.supportedFeatures.contains(.wifiAware)
    }

    var isServiceDeclared: Bool {
        WAPublishableService.allServices[LabConfiguration.serviceName] != nil
            && WASubscribableService.allServices[LabConfiguration.serviceName] != nil
    }

    var capabilitySummary: String {
        "Peers \(WACapabilities.maximumConnectableDevices) · Publish \(WACapabilities.maximumPublishableServices) · Subscribe \(WACapabilities.maximumSubscribableServices)"
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        log("Session \(sessionID) started")
        log("Wi-Fi Aware supported: \(isWiFiAwareSupported)")
        log("Service declared: \(isServiceDeclared) (\(LabConfiguration.serviceName))")
        pairedDevicesTask = Task { [weak self] in
            do {
                for try await devices in WAPairedDevice.allDevices {
                    guard let self else { return }
                    pairedDevices = devices.values.sorted { $0.id < $1.id }
                    log("Paired-device list updated: \(pairedDevices.count)")
                }
            } catch is CancellationError {
                return
            } catch {
                self?.log("Paired-device monitor failed: \(error)")
            }
        }
    }

    func startPublisher() {
        guard listenerTask == nil else {
            log("Publisher is already active")
            return
        }
        guard validateReady() else { return }

        let mode = performanceMode.value
        let serviceClass = accessCategory.serviceClass
        publisherStatus = "Starting…"
        log("Publisher requested (\(performanceMode.rawValue), \(accessCategory.rawValue))")

        listenerTask = Task { [weak self] in
            guard let self else { return }
            defer {
                listenerTask = nil
                if publisherStatus != "Failed" {
                    publisherStatus = "Stopped"
                }
            }

            do {
                try await NetworkListener(
                    for: .wifiAware(
                        .connecting(
                            to: LabConfiguration.publishableService,
                            from: .allPairedDevices
                        )
                    ),
                    using: .parameters {
                        Coder(
                            receiving: LabMessage.self,
                            sending: LabMessage.self,
                            using: NetworkJSONCoder()
                        ) {
                            UDP()
                        }
                    }
                    .wifiAware { $0.performanceMode = mode }
                    .serviceClass(serviceClass)
                )
                .onStateUpdate { [weak self] _, state in
                    self?.handlePublisherState(state)
                }
                .run { [weak self] connection in
                    self?.add(connection, direction: "Incoming")
                }
            } catch is CancellationError {
                log("Publisher stopped")
            } catch {
                publisherStatus = "Failed"
                log("Publisher failed: \(describe(error))")
            }
        }
    }

    func stopPublisher() {
        guard let listenerTask else { return }
        log("Stopping publisher")
        listenerTask.cancel()
        self.listenerTask = nil
        publisherStatus = "Stopped"
    }

    func startSubscriber() {
        guard browserTask == nil else {
            log("Subscriber browser is already active")
            return
        }
        guard validateReady() else { return }

        subscriberStatus = "Starting…"
        log("Subscriber browse requested")

        browserTask = Task { [weak self] in
            guard let self else { return }
            defer {
                browserTask = nil
                if subscriberStatus != "Failed" {
                    subscriberStatus = "Stopped"
                }
            }

            do {
                let endpoint = try await NetworkBrowser(
                    for: .wifiAware(
                        .connecting(
                            to: .allPairedDevices,
                            from: LabConfiguration.subscribableService
                        )
                    )
                )
                .onStateUpdate { [weak self] _, state in
                    self?.handleSubscriberState(state)
                }
                .run { [weak self] endpoints in
                    self?.subscriberStatus = "Browsing (\(endpoints.count) found)"
                    if let first = endpoints.first {
                        self?.log("Subscriber discovered \(first.device.labDisplayName)")
                        return .finish(first)
                    }
                    return .continue
                }

                log("Subscriber connecting to \(endpoint.device.labDisplayName)")
                connect(to: endpoint, direction: "Outgoing / browse")
            } catch is CancellationError {
                log("Subscriber browser stopped")
            } catch {
                subscriberStatus = "Failed"
                log("Subscriber failed: \(describe(error))")
            }
        }
    }

    func stopSubscriber() {
        guard let browserTask else { return }
        log("Stopping subscriber browser")
        browserTask.cancel()
        self.browserTask = nil
        subscriberStatus = "Stopped"
    }

    func selected(_ endpoint: WAEndpoint) {
        log("DevicePicker selected \(endpoint.device.labDisplayName)")
        connect(to: endpoint, direction: "Outgoing / picker")
    }

    func pairingAdvertiserTapped() {
        log("Publisher pairing UI opened")
    }

    func subscriberPickerTapped() {
        log("Subscriber device picker opened")
    }

    func sendPing(to connectionID: String) {
        guard let connection = activeConnections[connectionID] else {
            log("Ping skipped: connection \(connectionID) is not active")
            return
        }
        let ping = LabMessage(kind: .ping, session: sessionID, payload: "wifi-aware-lab")
        pendingPings[ping.id] = ping.sentAt
        Task { [weak self] in
            await self?.send(ping, over: connection)
        }
    }

    func sendPingToAll() {
        guard !activeConnections.isEmpty else {
            log("Ping skipped: no connections")
            return
        }
        for id in activeConnections.keys {
            sendPing(to: id)
        }
    }

    func refreshPerformance() {
        guard !activeConnections.isEmpty else {
            log("Metrics skipped: no connections")
            return
        }
        for connection in activeConnections.values {
            Task { [weak self] in
                await self?.updatePerformance(for: connection)
            }
        }
    }

    func clearLogs() {
        logs.removeAll()
        log("Log cleared")
    }

    var logText: String {
        logs.joined(separator: "\n")
    }

    private func validateReady() -> Bool {
        guard isWiFiAwareSupported else {
            log("Cannot start: this device does not report Wi-Fi Aware support")
            return false
        }
        guard isServiceDeclared else {
            log("Cannot start: \(LabConfiguration.serviceName) is missing from Info.plist")
            return false
        }
        return true
    }

    private func connect(to endpoint: WAEndpoint, direction: String) {
        guard validateReady() else { return }
        let mode = performanceMode.value
        let serviceClass = accessCategory.serviceClass

        let connection = NetworkConnection(
            to: endpoint,
            using: .parameters {
                Coder(
                    receiving: LabMessage.self,
                    sending: LabMessage.self,
                    using: NetworkJSONCoder()
                ) {
                    UDP()
                }
            }
            .wifiAware { $0.performanceMode = mode }
            .serviceClass(serviceClass)
        )
        add(connection, direction: direction)
    }

    private func add(_ connection: LabConnection, direction: String) {
        guard activeConnections[connection.id] == nil else { return }

        activeConnections[connection.id] = connection
        connections.insert(
            LabConnectionRow(
                id: connection.id,
                direction: direction,
                state: "Setup",
                device: "Resolving…",
                endpoints: "local: – / remote: –"
            ),
            at: 0
        )
        log("Connection added [\(shortID(connection.id))] \(direction)")

        connection.onStateUpdate { [weak self] connection, state in
            self?.handleConnectionState(connection, state: state)
        }

        receiverTasks[connection.id] = Task { [weak self] in
            do {
                for try await (message, _) in connection.messages {
                    await self?.receive(message, over: connection)
                }
            } catch is CancellationError {
                return
            } catch {
                self?.log("Receive failed [\(self?.shortID(connection.id) ?? connection.id)]: \(self?.describe(error) ?? String(describing: error))")
            }
        }
    }

    private func handleConnectionState(_ connection: LabConnection, state: LabConnection.State) {
        let stateText: String
        switch state {
        case .setup:
            stateText = "Setup"
        case .waiting(let error):
            stateText = "Waiting"
            log("Connection waiting [\(shortID(connection.id))]: \(describe(error))")
        case .preparing:
            stateText = "Preparing"
        case .ready:
            stateText = "Ready"
        case .failed(let error):
            stateText = "Failed"
            log("Connection failed [\(shortID(connection.id))]: \(describe(error))")
        case .cancelled:
            stateText = "Cancelled"
        @unknown default:
            stateText = "Unknown"
        }

        updateRow(connection.id) { row in
            row.state = stateText
            row.endpoints = "local: \(connection.localEndpoint?.debugDescription ?? "–") / remote: \(connection.remoteEndpoint?.debugDescription ?? "–")"
        }
        log("Connection [\(shortID(connection.id))] → \(stateText)")

        switch state {
        case .ready:
            Task { [weak self] in
                guard let self else { return }
                await updatePerformance(for: connection)
                await send(
                    LabMessage(kind: .hello, session: sessionID, payload: "iOS Wi-Fi Aware Lab"),
                    over: connection
                )
            }
        case .failed, .cancelled:
            activeConnections.removeValue(forKey: connection.id)
            receiverTasks.removeValue(forKey: connection.id)?.cancel()
        default:
            break
        }
    }

    private func handlePublisherState(_ state: NetworkListener<LabProtocol>.State) {
        switch state {
        case .setup:
            publisherStatus = "Setup"
        case .waiting(let error):
            publisherStatus = "Waiting"
            log("Publisher waiting: \(describe(error))")
        case .ready:
            publisherStatus = "Listening"
            log("Publisher is listening")
        case .failed(let error):
            publisherStatus = "Failed"
            log("Publisher state failed: \(describe(error))")
        case .cancelled:
            publisherStatus = "Stopped"
        @unknown default:
            publisherStatus = "Unknown"
        }
    }

    private func handleSubscriberState(_ state: NetworkBrowser<WASubscriberBrowser>.State) {
        switch state {
        case .setup:
            subscriberStatus = "Setup"
        case .waiting(let error):
            subscriberStatus = "Waiting"
            log("Subscriber waiting: \(describe(error))")
        case .ready:
            subscriberStatus = "Browsing"
            log("Subscriber is browsing")
        case .failed(let error):
            subscriberStatus = "Failed"
            log("Subscriber state failed: \(describe(error))")
        case .cancelled:
            subscriberStatus = "Stopped"
        @unknown default:
            subscriberStatus = "Unknown"
        }
    }

    private func receive(_ message: LabMessage, over connection: LabConnection) async {
        let peerSession = message.session
        log("RX \(message.kind.rawValue) [\(shortID(connection.id))] peer-session=\(peerSession)")

        switch message.kind {
        case .hello:
            break
        case .ping:
            let pong = LabMessage(
                kind: .pong,
                session: sessionID,
                replyTo: message.id,
                payload: "echo"
            )
            await send(pong, over: connection)
        case .pong:
            guard let replyTo = message.replyTo,
                  let startedAt = pendingPings.removeValue(forKey: replyTo) else { return }
            let milliseconds = Date().timeIntervalSince(startedAt) * 1_000
            updateRow(connection.id) { $0.roundTripMilliseconds = milliseconds }
            log(String(format: "RTT [\(shortID(connection.id))] %.2f ms", milliseconds))
        }
    }

    private func send(_ message: LabMessage, over connection: LabConnection) async {
        do {
            try await connection.send(message)
            log("TX \(message.kind.rawValue) [\(shortID(connection.id))] id=\(message.id.uuidString.prefix(8))")
        } catch {
            log("Send failed [\(shortID(connection.id))]: \(describe(error))")
        }
    }

    private func updatePerformance(for connection: LabConnection) async {
        do {
            guard let path = connection.currentPath,
                  let awarePath = try await path.wifiAware else {
                log("No Wi-Fi Aware path yet [\(shortID(connection.id))]")
                return
            }

            let report = awarePath.performance
            let latency = report.transmitLatency[accessCategory.value]?.average?.labMilliseconds
            let signal = report.signalStrength.map { String(format: "%.2f", $0) } ?? "–"
            let capacity = report.throughputCapacity.map { String(format: "%.2f Mbps", $0) } ?? "–"
            let latencyText = latency.map { String(format: "%.2f ms", $0) } ?? "–"
            let summary = "signal \(signal) · capacity \(capacity) · tx \(latencyText)"

            updateRow(connection.id) { row in
                row.device = awarePath.endpoint.device.labDisplayName
                row.performance = summary
            }
            log("Metrics [\(shortID(connection.id))] \(summary)")
        } catch {
            log("Metrics failed [\(shortID(connection.id))]: \(describe(error))")
        }
    }

    private func describe(_ error: any Error) -> String {
        guard let networkError = error as? NWError else {
            return String(describing: error)
        }
        guard let awareError = networkError.wifiAware else {
            return String(describing: networkError)
        }

        let category: String
        switch awareError {
        case .error:
            category = "error"
        case .wifiAwareUnsupported:
            category = "wifiAwareUnsupported"
        case .entitlementMissing:
            category = "entitlementMissing"
        case .noRadioResources:
            category = "noRadioResources"
        case .serviceNotDeclared:
            category = "serviceNotDeclared"
        case .serviceAlreadySubscribing:
            category = "serviceAlreadySubscribing"
        case .serviceAlreadyPublishing:
            category = "serviceAlreadyPublishing"
        case .noPairedDevices:
            category = "noPairedDevices"
        case .deviceInvalid:
            category = "deviceInvalid"
        case .deviceNoLongerAvailable:
            category = "deviceNoLongerAvailable"
        case .publisherTimeout:
            category = "publisherTimeout"
        case .subscriberTimeout:
            category = "subscriberTimeout"
        case .connectionFailed:
            category = "connectionFailed"
        case .connectionIdleTimeout:
            category = "connectionIdleTimeout"
        case .connectionTerminated:
            category = "connectionTerminated"
        @unknown default:
            category = "unknown"
        }
        return "WAError.\(category) (\(networkError))"
    }

    private func updateRow(_ id: String, change: (inout LabConnectionRow) -> Void) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        change(&connections[index])
    }

    private func shortID(_ id: String) -> String {
        String(id.prefix(8))
    }

    private func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        logs.append("\(formatter.string(from: Date()))  \(message)")
        if logs.count > 500 {
            logs.removeFirst(logs.count - 500)
        }
    }
}
