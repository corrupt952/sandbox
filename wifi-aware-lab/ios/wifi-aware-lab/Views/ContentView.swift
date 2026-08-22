import SwiftUI

struct ContentView: View {
  // MARK: - Properties

  @State private var viewModel = ContentViewModel()

  var body: some View {
    NavigationStack {
      List {
        statusRow
        environmentRow
        connectedSection
        pairedSection
        toolsSection
      }
      .listStyle(.insetGrouped)
      .navigationTitle(String(localized: "content.title", defaultValue: "Wi-Fi Aware Lab"))
      .toolbar { bottomBar }
      .task { viewModel.start() }
    }
  }

  // MARK: - Subviews

  @ViewBuilder
  private var statusRow: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(statusColor)
        .frame(width: 7, height: 7)
      Text(statusText)
        .font(.caption.monospaced())
      Spacer(minLength: 0)
    }
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
    .listRowInsets(.init(top: 0, leading: 20, bottom: 1, trailing: 20))
  }

  @ViewBuilder
  private var environmentRow: some View {
    Text(environmentText)
      .font(.caption.monospaced())
      .foregroundStyle(.secondary)
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
      .listRowInsets(.init(top: 0, leading: 20, bottom: 6, trailing: 20))
  }

  @ViewBuilder
  private var connectedSection: some View {
    Section {
      if viewModel.connectedLinks.isEmpty {
        Text(String(localized: "content.connected.empty", defaultValue: "Nothing connected yet"))
          .foregroundStyle(.secondary)
      } else {
        ForEach(viewModel.connectedLinks) { link in
          NavigationLink {
            LinkDetailView(link: link) { viewModel.sendPing(to: link.id) }
          } label: {
            LinkRowView(link: link)
          }
        }
      }
    } header: {
      HStack {
        Text(String(localized: "content.connected.header", defaultValue: "Connected"))
        Spacer()
        Text(connectedCountText)
          .monospacedDigit()
      }
    }
  }

  @ViewBuilder
  private var pairedSection: some View {
    Section(String(localized: "content.paired.header", defaultValue: "Paired")) {
      ForEach(viewModel.idleDevices) { device in
        VStack(alignment: .leading, spacing: 2) {
          Text(device.displayName)
            .foregroundStyle(.secondary)
          Text(device.detail)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }

      PairingControlsView(
        role: viewModel.currentRole,
        activeDuration: viewModel.settings.activeDuration.duration,
        onAdvertiseTap: { viewModel.didTapAdvertiseButton() },
        onPickerTap: { viewModel.didTapPickerButton() },
        onSelect: { viewModel.didSelectEndpoint($0) }
      )
    }
  }

  @ViewBuilder
  private var toolsSection: some View {
    Section {
      NavigationLink {
        RadioSettingsView(settings: $viewModel.settings)
      } label: {
        LabeledContent(
          String(localized: "content.tools.radioSettings", defaultValue: "Radio Settings")
        ) {
          Text(viewModel.settings.summary())
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }

      NavigationLink {
        EventLogView(logs: viewModel.logs, onClear: { viewModel.clearLogs() })
      } label: {
        LabeledContent(String(localized: "content.tools.eventLog", defaultValue: "Event Log")) {
          Text(latestLogText)
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
    }
  }

  @ToolbarContentBuilder
  private var bottomBar: some ToolbarContent {
    ToolbarItem(placement: .bottomBar) {
      Menu {
        Picker(
          String(localized: "content.role.picker", defaultValue: "Role"), selection: roleBinding
        ) {
          Text(String(localized: "content.role.publisher", defaultValue: "Publisher"))
            .tag(LabRole?.some(.publisher))
          Text(String(localized: "content.role.subscriber", defaultValue: "Subscriber"))
            .tag(LabRole?.some(.subscriber))
          Text(String(localized: "content.role.off", defaultValue: "Off"))
            .tag(LabRole?.none)
        }
      } label: {
        Text(roleLabel)
      }
    }

    ToolbarSpacer(.flexible, placement: .bottomBar)

    ToolbarItem(placement: .bottomBar) {
      Button(String(localized: "content.action.pingAll", defaultValue: "Ping All")) {
        viewModel.sendPingToAll()
      }
      .buttonStyle(.glassProminent)
      .disabled(viewModel.connectedLinks.isEmpty)
    }
  }

  // MARK: - Private methods

  private var roleBinding: Binding<LabRole?> {
    Binding(
      get: { viewModel.currentRole },
      set: { viewModel.selectRole($0) }
    )
  }

  /// The role that is selected, not how it is doing — the status belongs in the log.
  private var roleLabel: String {
    switch viewModel.currentRole {
    case .publisher: String(localized: "content.role.publisher", defaultValue: "Publisher")
    case .subscriber: String(localized: "content.role.subscriber", defaultValue: "Subscriber")
    case nil: String(localized: "content.role.off", defaultValue: "Off")
    }
  }

  private var statusText: String {
    switch viewModel.currentStatus {
    case .stopped:
      String(localized: "content.status.stopped", defaultValue: "Not running")
    case .starting:
      String(localized: "content.status.starting", defaultValue: "Starting…")
    case .setup:
      String(localized: "content.status.setup", defaultValue: "Setting up")
    case .waiting:
      String(localized: "content.status.waiting", defaultValue: "Waiting")
    case .ready:
      viewModel.currentRole == .publisher
        ? String(localized: "content.status.listening", defaultValue: "Listening")
        : String(localized: "content.status.browsing", defaultValue: "Browsing")
    case .browsing(let foundCount):
      String(
        localized: "content.status.browsingFound",
        defaultValue: "Browsing · \(foundCount) found"
      )
    case .failed:
      String(localized: "content.status.failed", defaultValue: "Failed")
    case .unknown:
      String(localized: "content.status.unknown", defaultValue: "Unknown")
    }
  }

  private var statusColor: Color {
    switch viewModel.currentStatus {
    case .ready, .browsing: .green
    case .starting, .setup, .waiting: .orange
    case .failed: .red
    case .stopped, .unknown: .secondary
    }
  }

  private var connectedCountText: String {
    String(
      localized: "content.connected.count",
      defaultValue: "\(viewModel.connectedLinks.count) of \(viewModel.maximumPeerCount)"
    )
  }

  private var environmentText: String {
    "\(viewModel.serviceName) · \(viewModel.sessionID) · \(viewModel.capabilitySummary)"
  }

  private var latestLogText: String {
    viewModel.latestLog ?? ""
  }
}

#Preview {
  ContentView()
}
