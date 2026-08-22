import SwiftUI

struct LinkRowView: View {
  // MARK: - Static properties

  private static let placeholder = "—"

  // MARK: - Properties

  let link: LabLink

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(link.deviceText)
          .lineLimit(1)
          .truncationMode(.tail)

        Spacer(minLength: 0)

        if let roundTrips = trend {
          RoundTripTrendView(roundTrips: roundTrips)
        }

        if let latest = link.latestRoundTrip {
          HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(String(format: "%.1f", latest.totalMilliseconds))
              .font(.title3.monospacedDigit().weight(.medium))
            Text("ms")
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
          }
        } else {
          Text(link.state.rawValue.lowercased())
            .font(.caption.monospaced())
            .foregroundStyle(stateColor)
        }
      }

      Text(detailText)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .padding(.vertical, 2)
  }

  // MARK: - Subviews

  private var trend: [Duration]? {
    link.roundTrips.count >= 2 ? link.roundTrips : nil
  }

  private var stateColor: Color {
    switch link.state {
    case .ready: .green
    case .failed, .cancelled: .red
    case .setup, .preparing, .waiting, .unknown: .orange
    }
  }

  private var detailText: String {
    let signal =
      link.metrics?.signalStrength.map { String(format: "%.2f", $0) } ?? Self.placeholder
    let capacity =
      link.metrics?.throughputCapacity.map { String(format: "%.0f Mbps", $0) } ?? Self.placeholder
    return
      "\(link.direction.shortText) · \(link.state.rawValue.lowercased()) · \(signal) · \(capacity)"
  }
}

#Preview("Ready with trend") {
  List {
    LinkRowView(
      link: LabLink(
        id: "3F2A11C0",
        direction: .incoming,
        state: .ready,
        deviceName: "iPad Pro",
        roundTrips: [.milliseconds(15), .milliseconds(14), .milliseconds(13)],
        metrics: LabLinkMetrics(
          signalStrength: 0.96,
          throughputCapacity: 1200.98,
          transmitLatency: .milliseconds(9),
          deviceName: "iPad Pro"
        )
      )
    )
  }
}

#Preview("Preparing") {
  List {
    LinkRowView(
      link: LabLink(
        id: "9C4D01A2", direction: .incoming, state: .preparing, deviceName: "iPad mini")
    )
  }
}
