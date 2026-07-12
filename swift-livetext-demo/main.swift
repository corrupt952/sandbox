// Live Text (VisionKit) で画像内の文字選択 + 全文抽出を試す最小デモ。
//
// 実行: swift main.swift
// 要件: macOS 13+ (Ventura) / Apple Silicon または Intel Mac (Neural Engine 必要)
//
// 動作:
//   1. アプリ起動
//   2. 「画像を開く」ボタンで任意の画像を選択
//   3. 画像表示後、自動で OCR (ImageAnalyzer) が走る
//   4. 完了したら画像内の文字を長押し/ドラッグで選択、コピー可能
//   5. 「テキスト抽出」ボタンでサイドに全文表示 (analysis.transcript, macOS 14+)
//   6. 選択中のテキストはサイドに自動表示 (0.3 秒間隔で overlay.selectedText を poll)

import AppKit
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import VisionKit

struct LiveTextDemoApp: App {
  var body: some Scene {
    WindowGroup("Live Text Demo") {
      ContentView()
        .frame(minWidth: 1000, minHeight: 600)
    }
  }
}

LiveTextDemoApp.main()

struct ContentView: View {
  /// 元の入力画像 (常に保持。前処理 OFF に戻したい時の戻り先)。
  @State private var rawImage: NSImage?
  /// 現在表示・解析対象になっている画像 (raw か preprocessed のどちらか)。
  @State private var image: NSImage?
  @State private var analysis: ImageAnalysis?
  @State private var status: String = "画像を選択してください"
  @State private var extractedText: String = ""
  @State private var selectedText: String = ""

  // ─── 前処理パラメータ ─────────────────────────
  @State private var preprocessingEnabled: Bool = false
  @State private var contrast: Double = 1.5  // 1.0 = 等倍、上げるほど強調
  @State private var saturation: Double = 0  // 0 = 完全グレースケール

  /// `ImageAnalysisOverlayView` の参照を保持するためのプロキシ。
  /// `selectedText` 取得用に SwiftUI 外から触れるようにしておく。
  @State private var overlayRef = OverlayReference()

  /// 0.3 秒間隔で `overlay.selectedText` を読み取り、SwiftUI 側に反映する。
  /// (delegate にも selection 変更通知はないため、最も確実な手段は poll)
  private let pollTimer =
    Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      HStack(spacing: 0) {
        imagePane
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        Divider()
        sidebar
          .frame(width: 320)
          .layoutPriority(1)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .onReceive(pollTimer) { _ in
      let current = overlayRef.overlay?.selectedText ?? ""
      if current != selectedText { selectedText = current }
    }
  }

  // MARK: - Subviews

  private var toolbar: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Button("画像を開く") { openImage() }
        Button("テキスト抽出") { extractAll() }
          .disabled(analysis == nil)
        Toggle("前処理 ON", isOn: $preprocessingEnabled)
          .toggleStyle(.switch)
          .onChange(of: preprocessingEnabled) { _, _ in applyPreprocessingAndAnalyze() }
        Button("再解析") { applyPreprocessingAndAnalyze() }
          .disabled(rawImage == nil)
        Text(status)
          .foregroundStyle(.secondary)
          .font(.callout)
          .lineLimit(1)
        Spacer()
      }

      // 前処理 ON の時だけスライダーを出す。値変更直後の自動再解析は重いので「再解析」
      // ボタンを明示的に押すフローにしてある。
      if preprocessingEnabled {
        HStack {
          Text("Contrast \(String(format: "%.1f", contrast))")
            .font(.caption)
            .frame(width: 110, alignment: .leading)
          Slider(value: $contrast, in: 0.5...3.0)
            .frame(maxWidth: 200)

          Text("Saturation \(String(format: "%.1f", saturation))")
            .font(.caption)
            .frame(width: 120, alignment: .leading)
          Slider(value: $saturation, in: 0...1)
            .frame(maxWidth: 200)
          Spacer()
        }
        .font(.callout)
      }
    }
    .padding(8)
  }

  private var imagePane: some View {
    Group {
      if let image {
        ImageOverlayView(image: image, analysis: analysis, overlayRef: overlayRef)
          .background(Color.black.opacity(0.05))
      } else {
        Rectangle()
          .fill(Color.black.opacity(0.05))
          .overlay(
            Text("「画像を開く」を押してください")
              .foregroundStyle(.secondary)
          )
      }
    }
    .padding(8)
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("選択中のテキスト")
        .font(.headline)
      TextEditor(text: .constant(selectedText))
        .font(.body)
        .frame(maxHeight: .infinity)
        .border(Color.gray.opacity(0.3))

      Divider()

      Text("抽出されたテキスト (全文)")
        .font(.headline)
      TextEditor(text: .constant(extractedText))
        .font(.body)
        .frame(maxHeight: .infinity)
        .border(Color.gray.opacity(0.3))
    }
    .padding(8)
  }

  // MARK: - Actions

  private func openImage() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK,
      let url = panel.url,
      let nsImage = NSImage(contentsOf: url)
    else { return }

    rawImage = nsImage
    extractedText = ""
    selectedText = ""
    applyPreprocessingAndAnalyze()
  }

  /// 現在の前処理設定 (ON/OFF + contrast/saturation) を `rawImage` に適用して
  /// `image` に反映、その上で再 OCR をキック。
  private func applyPreprocessingAndAnalyze() {
    guard let rawImage else { return }
    let processed: NSImage
    if preprocessingEnabled {
      processed =
        preprocess(rawImage, contrast: contrast, saturation: saturation) ?? rawImage
    } else {
      processed = rawImage
    }
    image = processed
    analysis = nil
    status = preprocessingEnabled ? "前処理 + OCR 解析中..." : "OCR 解析中..."
    analyze(image: processed)
  }

  /// `CIColorControls` でコントラストと彩度を調整。
  /// saturation=0 で完全グレースケール、contrast を上げると明暗差が強調されて、
  /// 「色付き紙背景の雑誌」などで OCR ヒット率が上がる傾向。
  private func preprocess(_ image: NSImage, contrast: Double, saturation: Double) -> NSImage? {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return nil
    }
    let ciImage = CIImage(cgImage: cgImage)
    let filter = CIFilter.colorControls()
    filter.inputImage = ciImage
    filter.contrast = Float(contrast)
    filter.saturation = Float(saturation)
    filter.brightness = 0

    guard let output = filter.outputImage else { return nil }
    let context = CIContext()
    guard let outCG = context.createCGImage(output, from: output.extent) else { return nil }
    return NSImage(cgImage: outCG, size: image.size)
  }

  private func analyze(image: NSImage) {
    Task {
      guard ImageAnalyzer.isSupported else {
        await MainActor.run {
          status = "このデバイスは ImageAnalyzer 非対応 (Neural Engine 必須)"
        }
        return
      }

      guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        await MainActor.run { status = "CGImage 取得失敗" }
        return
      }

      let analyzer = ImageAnalyzer()
      let configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode])

      do {
        let result = try await analyzer.analyze(
          cgImage, orientation: .up, configuration: configuration)
        await MainActor.run {
          self.analysis = result
          self.status =
            result.hasResults(for: [.text])
            ? "解析完了 — 画像内の文字を選択 / 抽出できます"
            : "解析完了 — テキスト未検出"
        }
      } catch {
        await MainActor.run { status = "解析エラー: \(error.localizedDescription)" }
      }
    }
  }

  private func extractAll() {
    guard let analysis else { return }
    if #available(macOS 14, *) {
      extractedText = analysis.transcript
    } else {
      extractedText = "(macOS 14+ で analysis.transcript 利用可)"
    }
  }
}

/// `ImageAnalysisOverlayView` への参照を SwiftUI 状態経由で持ち回るためのプロキシ。
/// SwiftUI 内から `selectedText` を直接読むためには NSView 実体への参照が必要なので
/// この箱越しに poll する。
final class OverlayReference {
  var overlay: ImageAnalysisOverlayView?
}

/// NSImageView + ImageAnalysisOverlayView を重ねた最小コンテナ。
/// overlay は trackingImageView 経由で imageView の表示変換 (aspect-fit 等) を追従する。
struct ImageOverlayView: NSViewRepresentable {
  let image: NSImage
  let analysis: ImageAnalysis?
  let overlayRef: OverlayReference

  func makeNSView(context: Context) -> NSView {
    let container = NSView()
    container.wantsLayer = true

    let imageView = NSImageView()
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.translatesAutoresizingMaskIntoConstraints = false
    // 大きな画像を入れると intrinsicContentSize が SwiftUI の HStack を押し広げ、
    // サイドバー (.frame(width: 320)) がウィンドウ外に出てしまうため、hugging を
    // 最低・compression resistance も最低にして「外側の指示通り縮む」ようにする。
    imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
    imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
    imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

    let overlay = ImageAnalysisOverlayView()
    overlay.trackingImageView = imageView
    overlay.preferredInteractionTypes = [.automatic]
    overlay.translatesAutoresizingMaskIntoConstraints = false

    container.addSubview(imageView)
    container.addSubview(overlay)

    NSLayoutConstraint.activate([
      imageView.topAnchor.constraint(equalTo: container.topAnchor),
      imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      overlay.topAnchor.constraint(equalTo: imageView.topAnchor),
      overlay.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
      overlay.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
      overlay.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),
    ])

    context.coordinator.imageView = imageView
    context.coordinator.overlay = overlay
    overlayRef.overlay = overlay
    return container
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.imageView?.image = image
    context.coordinator.overlay?.analysis = analysis
    overlayRef.overlay = context.coordinator.overlay
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator {
    var imageView: NSImageView?
    var overlay: ImageAnalysisOverlayView?
  }
}
