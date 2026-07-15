import DeviceDiscoveryUI
import Foundation
import Network
import SwiftUI
import UIKit
import WiFiAware

struct ContentView: View {
    @State private var model = WiFiAwareLabModel()

    var body: some View {
        NavigationStack {
            List {
                overviewSection
                configurationSection
                pairingSection
                transportSection
                pairedDevicesSection
                connectionsSection
                logSection
            }
            .navigationTitle("Wi-Fi Aware Lab")
            .task { model.start() }
        }
    }

    private var overviewSection: some View {
        Section("Experiment") {
            LabeledContent("Session", value: model.sessionID)
            LabeledContent("Service", value: LabConfiguration.serviceName)
            LabeledContent("Hardware") {
                Label(
                    model.isWiFiAwareSupported ? "Supported" : "Unavailable",
                    systemImage: model.isWiFiAwareSupported ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .foregroundStyle(model.isWiFiAwareSupported ? .green : .red)
            }
            LabeledContent("Declaration") {
                if model.isServiceDeclared {
                    Text("Publish + Subscribe")
                        .foregroundStyle(.green)
                } else {
                    Text("Missing")
                        .foregroundStyle(.red)
                }
            }
            Text(model.capabilitySummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var configurationSection: some View {
        Section("Radio configuration") {
            Picker("Performance", selection: $model.performanceMode) {
                ForEach(LabPerformanceMode.allCases) { mode in
                    Text(mode.rawValue.capitalized).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Picker("Access category", selection: $model.accessCategory) {
                ForEach(LabAccessCategory.allCases) { category in
                    Text(category.rawValue).tag(category)
                }
            }

            Text("The selected values apply to newly created listeners and connections.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var pairingSection: some View {
        Section("Pairing") {
            DevicePairingView(
                .wifiAware(
                    .connecting(
                        to: LabConfiguration.publishableService,
                        from: .userSpecifiedDevices
                    )
                )
            ) {
                Label("Advertise publisher", systemImage: "antenna.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
            } fallback: {
                Label("Pairing unavailable", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .simultaneousGesture(TapGesture().onEnded { model.pairingAdvertiserTapped() })
            .buttonStyle(.borderedProminent)

            DevicePicker(
                .wifiAware(
                    .connecting(
                        to: .userSpecifiedDevices,
                        from: LabConfiguration.subscribableService
                    )
                )
            ) { endpoint in
                model.selected(endpoint)
            } label: {
                Label("Pick publisher", systemImage: "dot.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
            } fallback: {
                Label("Picker unavailable", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .simultaneousGesture(TapGesture().onEnded { model.subscriberPickerTapped() })
            .buttonStyle(.bordered)

            Text("These system controls establish trust between devices before publisher and subscriber connections are created.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var transportSection: some View {
        Section("Network roles") {
            LabeledContent("Publisher", value: model.publisherStatus)
            HStack {
                Button("Start publisher", systemImage: "play.fill") {
                    model.startPublisher()
                }
                .buttonStyle(.borderedProminent)

                Button("Stop", systemImage: "stop.fill", role: .destructive) {
                    model.stopPublisher()
                }
                .buttonStyle(.bordered)
            }

            LabeledContent("Subscriber", value: model.subscriberStatus)
            HStack {
                Button("Browse & connect", systemImage: "magnifyingglass") {
                    model.startSubscriber()
                }
                .buttonStyle(.borderedProminent)

                Button("Stop", systemImage: "stop.fill", role: .destructive) {
                    model.stopSubscriber()
                }
                .buttonStyle(.bordered)
            }

            HStack {
                Button("Ping all", systemImage: "wave.3.right") {
                    model.sendPingToAll()
                }
                Button("Refresh metrics", systemImage: "gauge.with.dots.needle.50percent") {
                    model.refreshPerformance()
                }
            }
        }
    }

    @ViewBuilder
    private var pairedDevicesSection: some View {
        Section("Paired devices (\(model.pairedDevices.count))") {
            if model.pairedDevices.isEmpty {
                Text("No paired Wi-Fi Aware devices")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.pairedDevices) { device in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.labDisplayName)
                        Text(device.labDescription)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var connectionsSection: some View {
        Section("Connections (\(model.connections.count))") {
            if model.connections.isEmpty {
                Text("No connection attempts yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.connections) { connection in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Circle()
                                .fill(connection.state == "Ready" ? .green : .gray)
                                .frame(width: 8, height: 8)
                            Text("\(connection.direction) · \(connection.state)")
                                .font(.headline)
                            Spacer()
                            Button("Ping") { model.sendPing(to: connection.id) }
                                .buttonStyle(.bordered)
                        }
                        Text(connection.device)
                        Text(String(connection.id.prefix(8)))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(connection.endpoints)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if let rtt = connection.roundTripMilliseconds {
                            Text(String(format: "RTT %.2f ms", rtt))
                                .font(.caption.monospacedDigit())
                        }
                        if let performance = connection.performance {
                            Text(performance)
                                .font(.caption.monospaced())
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var logSection: some View {
        Section {
            ScrollView(.horizontal) {
                Text(model.logText.isEmpty ? "No events" : model.logText)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 180, maxHeight: 320)
        } header: {
            HStack {
                Text("Event log")
                Spacer()
                Button("Copy") { UIPasteboard.general.string = model.logText }
                Button("Clear") { model.clearLogs() }
            }
            .textCase(nil)
        }
    }
}

#Preview {
    ContentView()
}
