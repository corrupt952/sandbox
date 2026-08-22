import SwiftUI

struct RadioSettingsView: View {
  // MARK: - Properties

  @Binding var settings: LabRadioSettings

  var body: some View {
    List {
      Section {
        Picker(
          String(localized: "radioSettings.performance.label", defaultValue: "Performance"),
          selection: $settings.performanceMode
        ) {
          ForEach(LabPerformanceMode.allCases) { mode in
            Text(mode.rawValue.capitalized).tag(mode)
          }
        }

        Picker(
          String(localized: "radioSettings.accessCategory.label", defaultValue: "Access category"),
          selection: $settings.accessCategory
        ) {
          ForEach(LabAccessCategory.allCases) { category in
            Text(category.rawValue).tag(category)
          }
        }
      } footer: {
        Text(
          String(
            localized: "radioSettings.performance.footer",
            defaultValue: "Applies to listeners and connections created from now on."
          )
        )
      }

      Section {
        Picker(
          String(localized: "radioSettings.heartbeat.label", defaultValue: "Heartbeat"),
          selection: $settings.heartbeat
        ) {
          ForEach(LabHeartbeat.allCases) { heartbeat in
            Text(heartbeat.rawValue).tag(heartbeat)
          }
        }
        .pickerStyle(.segmented)
      } footer: {
        Text(
          String(
            localized: "radioSettings.heartbeat.footer",
            defaultValue:
              "Pings every connected link on a timer so the trend keeps moving. Heartbeat pings stay out of the log. Turn it off to let links go idle, which is what closes them after a few minutes."
          )
        )
      }

      Section {
        Picker(
          String(
            localized: "radioSettings.connectionLimit.label", defaultValue: "Connection limit"),
          selection: $settings.connectionLimit
        ) {
          ForEach(LabConnectionLimit.allCases) { limit in
            Text(limit.rawValue).tag(limit)
          }
        }
      } footer: {
        Text(
          String(
            localized: "radioSettings.connectionLimit.footer",
            defaultValue:
              "Caps how many incoming connections the publisher accepts. A small value reproduces the peer limit without gathering that many devices."
          )
        )
      }

      Section {
        Picker(
          String(localized: "radioSettings.activeDuration.label", defaultValue: "Active duration"),
          selection: $settings.activeDuration
        ) {
          ForEach(LabActiveDuration.allCases) { duration in
            Text(duration.rawValue).tag(duration)
          }
        }
        .pickerStyle(.segmented)
      } footer: {
        Text(
          String(
            localized: "radioSettings.activeDuration.footer",
            defaultValue:
              "How long publishing and browsing are requested to stay up, including the pairing control. Default leaves it to the system."
          )
        )
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle(String(localized: "radioSettings.title", defaultValue: "Radio Settings"))
    .navigationBarTitleDisplayMode(.inline)
  }
}

#Preview {
  @Previewable @State var settings = LabRadioSettings.default

  NavigationStack {
    RadioSettingsView(settings: $settings)
  }
}
