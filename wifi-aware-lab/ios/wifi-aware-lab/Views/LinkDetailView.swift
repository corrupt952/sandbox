import SwiftUI

struct LinkDetailView: View {
  // MARK: - Static properties

  private static let placeholder = "—"

  // MARK: - Properties

  let link: LabLink
  let onPing: () -> Void

  var body: some View {
    List {
      roundTripSection
      linkSection
      metricsSection
    }
    .listStyle(.insetGrouped)
    .navigationTitle(link.deviceText)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .bottomBar) {
        Button(String(localized: "linkDetail.action.ping", defaultValue: "Ping"), action: onPing)
          .buttonStyle(.glassProminent)
          .disabled(!link.state.isActive)
      }
    }
  }

  // MARK: - Subviews

  @ViewBuilder
  private var roundTripSection: some View {
    Section(String(localized: "linkDetail.roundTrip.header", defaultValue: "Round Trip")) {
      if link.roundTrips.isEmpty {
        Text(String(localized: "linkDetail.roundTrip.empty", defaultValue: "Not pinged yet"))
          .foregroundStyle(.secondary)
      } else {
        ForEach(Array(link.roundTrips.enumerated().reversed()), id: \.offset) { index, roundTrip in
          LabeledContent(
            "#\(index + 1)",
            value: String(format: "%.2f ms", roundTrip.totalMilliseconds)
          )
          .monospaced()
        }
      }
    }
  }

  @ViewBuilder
  private var linkSection: some View {
    Section(String(localized: "linkDetail.link.header", defaultValue: "Link")) {
      LabeledContent(
        String(localized: "linkDetail.link.direction", defaultValue: "Direction"),
        value: link.direction.rawValue
      )
      LabeledContent(
        String(localized: "linkDetail.link.state", defaultValue: "State"),
        value: link.state.rawValue
      )
      LabeledContent(
        String(localized: "linkDetail.link.id", defaultValue: "ID"),
        value: link.shortID
      )
      .monospaced()
      LabeledContent(
        String(localized: "linkDetail.link.local", defaultValue: "Local"),
        value: link.localEndpoint ?? Self.placeholder
      )
      .monospaced()
      .textSelection(.enabled)
      LabeledContent(
        String(localized: "linkDetail.link.remote", defaultValue: "Remote"),
        value: link.remoteEndpoint ?? Self.placeholder
      )
      .monospaced()
      .textSelection(.enabled)
    }
  }

  @ViewBuilder
  private var metricsSection: some View {
    Section(String(localized: "linkDetail.metrics.header", defaultValue: "Metrics")) {
      if let metrics = link.metrics {
        LabeledContent(
          String(localized: "linkDetail.metrics.signal", defaultValue: "Signal"),
          value: metrics.signalStrength.map { String(format: "%.2f", $0) } ?? Self.placeholder
        )
        LabeledContent(
          String(localized: "linkDetail.metrics.capacity", defaultValue: "Capacity"),
          value: metrics.throughputCapacity.map { String(format: "%.2f Mbps", $0) }
            ?? Self.placeholder
        )
        LabeledContent(
          String(localized: "linkDetail.metrics.transmitLatency", defaultValue: "Transmit latency"),
          value: metrics.transmitLatency.map { String(format: "%.2f ms", $0.totalMilliseconds) }
            ?? Self.placeholder
        )
      } else {
        Text(String(localized: "linkDetail.metrics.empty", defaultValue: "No Wi-Fi Aware path yet"))
          .foregroundStyle(.secondary)
      }
    }
  }
}

#Preview("Ready") {
  NavigationStack {
    LinkDetailView(
      link: LabLink(
        id: "3F2A11C0",
        direction: .incoming,
        state: .ready,
        deviceName: "iPad Pro",
        localEndpoint: "fe80::1%awdl0.49152",
        remoteEndpoint: "fe80::2%awdl0.49153",
        roundTrips: [.milliseconds(15), .milliseconds(14), .milliseconds(13)],
        metrics: LabLinkMetrics(
          signalStrength: 0.96,
          throughputCapacity: 1200.98,
          transmitLatency: .milliseconds(9),
          deviceName: "iPad Pro"
        )
      ),
      onPing: {}
    )
  }
}

#Preview("Preparing") {
  NavigationStack {
    LinkDetailView(
      link: LabLink(
        id: "9C4D01A2",
        direction: .incoming,
        state: .preparing,
        deviceName: "iPad mini"
      ),
      onPing: {}
    )
  }
}
