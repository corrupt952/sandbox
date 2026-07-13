//
//  ContentView.swift
//  BevLab
//
//  Created by K@zuki. on 2026/07/12.
//

import SwiftUI

struct ContentView: View {
  @State private var viewModel = BEVViewModel()

  /// Temp-file URL of a just-captured BEV snapshot; non-nil while the share
  /// sheet is presented.
  @State private var snapshotShareURL: URL?

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .topTrailing) {
        ARViewContainer(viewModel: viewModel)
          .ignoresSafeArea()

        bevPanel(width: proxy.size.width * 0.4)
          .padding()

        VStack {
          Spacer()
          controls
        }
      }
    }
    .onAppear { viewModel.start() }
    .onDisappear { viewModel.stop() }
    .sheet(
      isPresented: Binding(
        get: { snapshotShareURL != nil },
        set: { if $0 == false { snapshotShareURL = nil } })
    ) {
      if let snapshotShareURL {
        ActivityShareSheet(activityItems: [snapshotShareURL])
      }
    }
  }

  // MARK: - Subviews

  private func bevPanel(width: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("BEV")
          .font(.caption.bold())
          .foregroundStyle(.white)
        Spacer()
        Button {
          didTapSnapshotButton()
        } label: {
          Image(systemName: "square.and.arrow.up")
            .font(.caption.bold())
            .foregroundStyle(.white)
        }
        .disabled(viewModel.bevImage == nil)
      }

      ZStack {
        Color.black.opacity(0.6)
        if let bevImage = viewModel.bevImage {
          Image(decorative: bevImage, scale: 1, orientation: .up)
            .resizable()
            .aspectRatio(contentMode: .fit)
        } else {
          Image(systemName: "viewfinder")
            .font(.largeTitle)
            .foregroundStyle(.white.opacity(0.5))
        }
      }
      .aspectRatio(1, contentMode: .fit)
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color.white.opacity(0.7), lineWidth: 1))
    }
    .frame(width: width)
  }

  private var controls: some View {
    VStack(spacing: 8) {
      Text(viewModel.statusText)
        .font(.footnote)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.6), in: Capsule())

      HStack {
        Text("Rect: \(viewModel.rectSize, specifier: "%.1f") m")
          .font(.caption)
          .foregroundStyle(.white)
        Slider(value: $viewModel.rectSize, in: 1.0...4.0, step: 0.25)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
      .padding(.horizontal)
      .disabled(viewModel.hasGroundPlane == false)
    }
    .padding(.bottom, 24)
  }

  // MARK: - Private methods

  /// Captures the current BEV image as a native-resolution PNG and presents
  /// the share sheet for it.
  private func didTapSnapshotButton() {
    guard let snapshot = viewModel.makeSnapshot() else { return }
    snapshotShareURL = snapshot.writeToTemporaryFile()
  }
}

#Preview {
  ContentView()
}
