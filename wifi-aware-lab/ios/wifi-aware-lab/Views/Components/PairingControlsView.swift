import DeviceDiscoveryUI
import Foundation
import SwiftUI
import WiFiAware

// The only view that imports these frameworks: `DevicePicker`'s `onSelect` hands back a
// `WAEndpoint`, which this view wraps as `LabEndpointProtocol` so nothing above it sees the type.
struct PairingControlsView: View {
  // MARK: - Properties

  let role: LabRole?
  let activeDuration: Duration?
  let onAdvertiseTap: () -> Void
  let onPickerTap: () -> Void
  let onSelect: (any LabEndpointProtocol) -> Void

  var body: some View {
    // Each role pairs from one side only: a publisher advertises itself, a subscriber picks.
    switch role {
    case .subscriber:
      pickerControl
    case .publisher, nil:
      advertiseControl
    }
  }

  // MARK: - Subviews

  @ViewBuilder
  private var advertiseControl: some View {
    DevicePairingView(
      .wifiAware(
        .connecting(to: LabConfiguration.publishableService, from: .userSpecifiedDevices),
        active: activeDuration
      )
    ) {
      pairingLabel
    } fallback: {
      unavailableLabel
    }
    .simultaneousGesture(TapGesture().onEnded { onAdvertiseTap() })
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private var pickerControl: some View {
    DevicePicker(
      .wifiAware(
        .connecting(to: .userSpecifiedDevices, from: LabConfiguration.subscribableService),
        active: activeDuration
      )
    ) { endpoint in
      onSelect(WiFiAwareEndpoint(endpoint: endpoint))
    } label: {
      pairingLabel
    } fallback: {
      unavailableLabel
    }
    .simultaneousGesture(TapGesture().onEnded { onPickerTap() })
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private var pairingLabel: some View {
    Text(String(localized: "pairing.action.pair", defaultValue: "Pair a Device"))
      .foregroundStyle(Color.accentColor)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(.rect)
  }

  @ViewBuilder
  private var unavailableLabel: some View {
    Text(String(localized: "pairing.state.unavailable", defaultValue: "Pairing unavailable"))
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

#Preview("Publisher") {
  List {
    Section("Paired") {
      PairingControlsView(
        role: .publisher,
        activeDuration: nil,
        onAdvertiseTap: {},
        onPickerTap: {},
        onSelect: { _ in }
      )
    }
  }
}

#Preview("Subscriber") {
  List {
    Section("Paired") {
      PairingControlsView(
        role: .subscriber,
        activeDuration: nil,
        onAdvertiseTap: {},
        onPickerTap: {},
        onSelect: { _ in }
      )
    }
  }
}
