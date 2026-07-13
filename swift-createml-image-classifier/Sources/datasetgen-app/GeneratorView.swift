import SwiftUI

struct GeneratorView: View {
  @State private var viewModel = GeneratorViewModel()

  var body: some View {
    Form {
      Section("Classes") {
        ForEach($viewModel.classes) { $spec in
          HStack {
            TextField("Label", text: $spec.label)
              .frame(width: 120)
            TextField("Prompt", text: $spec.prompt)
            Button(role: .destructive) {
              viewModel.removeClass(spec)
            } label: {
              Image(systemName: "minus.circle")
            }
          }
        }
        Button("Add class") {
          viewModel.addClass()
        }
      }

      Section("Settings") {
        Picker("Style", selection: $viewModel.selectedStyleIndex) {
          ForEach(Array(viewModel.styleNames.enumerated()), id: \.offset) { index, name in
            Text(name).tag(index)
          }
        }
        Stepper(
          "Images per class: \(viewModel.countPerClass)",
          value: $viewModel.countPerClass,
          in: 4...200,
          step: 4
        )
        HStack {
          Text(viewModel.outputDirectory?.path ?? "No output directory")
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer()
          Button("Choose...") {
            chooseOutputDirectory()
          }
        }
      }

      Section {
        Button(viewModel.isGenerating ? "Generating..." : "Generate") {
          viewModel.generate()
        }
        .disabled(viewModel.isGenerating || viewModel.styleNames.isEmpty)

        if !viewModel.statusMessage.isEmpty {
          Text(viewModel.statusMessage)
            .foregroundStyle(.secondary)
        }
        if let errorMessage = viewModel.errorMessage {
          Text(errorMessage)
            .foregroundStyle(.red)
        }
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 520, minHeight: 420)
    .onAppear {
      viewModel.loadStyles()
    }
  }

  private func chooseOutputDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    if panel.runModal() == .OK {
      viewModel.outputDirectory = panel.url
    }
  }
}
