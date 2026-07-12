//
//  ContentView.swift
//  BevLab
//
//  Created by K@zuki. on 2026/07/12.
//

import SwiftUI

struct ContentView: View {
  @State private var viewModel = BEVViewModel()

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
  }

  // MARK: - Subviews

  private func bevPanel(width: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("BEV")
        .font(.caption.bold())
        .foregroundStyle(.white)

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
}

#Preview {
  ContentView()
}
