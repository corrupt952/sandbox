// render-bench — Bookil の初期描画パスを忠実に再現したレンダリング速度計測ツール（単一ファイル）
//
// 対象ロジック（アプリ本体から分離・移植）:
//   - CGPDFDocumentAdapter.fullPageImageOnRenderQueue : フルページ raster 生成
//   - ReaderColorTheme.apply                          : テーマフィルタ(CIColorInvert/CISepiaTone)
//   - PDFPageRenderScalePolicy.targetScale            : 実機相当のレンダースケール算出
//
// 計測区間（signpost 相当）:
//   snapshot → contextAlloc → drawSetup → drawPDF → makeImage → themeApply(CIbuild+render)
//
// cold（初回・CIContext/GPU 起動含む）と warm（中央値）を分けて記録する。
//
// 実行:  swift main.swift
// ビルド: swiftc -O main.swift -o render-bench && ./render-bench

import CoreGraphics
import CoreImage
import Foundation

// MARK: - Timing

@inline(__always) func nowSeconds() -> Double {
  var ts = timespec()
  clock_gettime(CLOCK_MONOTONIC, &ts)
  return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
}

@inline(__always) func measure<T>(_ body: () -> T) -> (value: T, ms: Double) {
  let start = nowSeconds()
  let value = body()
  return (value, (nowSeconds() - start) * 1000)
}

func median(_ xs: [Double]) -> Double {
  guard !xs.isEmpty else { return 0 }
  let sorted = xs.sorted()
  let mid = sorted.count / 2
  return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
}

// MARK: - ReaderColorTheme（アプリ本体から移植）

enum ReaderColorTheme: String, CaseIterable {
  case off
  case night
  case sepia

  // CIContext is expensive to create. 1 インスタンスを共有（アプリ本体と同設計）。
  static let sharedCIContext = CIContext()

  /// アプリ本体 ReaderColorTheme.apply を忠実移植。CIImage 構築と createCGImage を
  /// 別々に計測できるよう、所要時間を返すよう拡張している。
  func applyTimed(
    to image: CGImage,
    sepiaIntensity: Double = 1.0
  ) -> (image: CGImage?, ciBuildMs: Double, renderMs: Double) {
    // off は zero-cost fast path（contrast/grain は本ベンチでは中立固定）。
    if self == .off {
      return (image, 0, 0)
    }

    let build = measure { () -> CIImage in
      var ciImage = CIImage(cgImage: image)
      switch self {
      case .off:
        break
      case .night:
        ciImage = ciImage.applyingFilter("CIColorInvert")
      case .sepia:
        ciImage = ciImage.applyingFilter(
          "CISepiaTone", parameters: [kCIInputIntensityKey: sepiaIntensity])
      }
      return ciImage
    }
    let ciImage = build.value

    let render = measure { () -> CGImage? in
      ReaderColorTheme.sharedCIContext.createCGImage(ciImage, from: ciImage.extent)
    }
    return (render.value ?? image, build.ms, render.ms)
  }
}

// MARK: - Scale policy（アプリ本体 PDFPageRenderScalePolicy から移植）

enum PDFPageRenderScalePolicy {
  static let maximumScaleFactor: CGFloat = 4.0  // ZoomPolicy.defaultMaximumZoomScale

  static func targetScale(
    pageBox: CGRect, rotation: Int, viewBounds: CGRect, screenScale: CGFloat
  ) -> CGFloat {
    let r = ((rotation % 360) + 360) % 360
    let rw = (r == 90 || r == 270) ? pageBox.height : pageBox.width
    let rh = (r == 90 || r == 270) ? pageBox.width : pageBox.height
    guard rw > 0, rh > 0 else { return 0 }
    let scaleFromBounds: CGFloat
    if !viewBounds.isEmpty {
      scaleFromBounds = max(viewBounds.width / rw, viewBounds.height / rh)
    } else {
      scaleFromBounds = 1
    }
    return min(max(1, scaleFromBounds), maximumScaleFactor) * screenScale
  }
}

// MARK: - CGContext helper（アプリ本体から移植）

extension CGContext {
  static func makeRGBAContext(width: Int, height: Int) -> CGContext? {
    CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  }
}

// MARK: - Render path（CGPDFDocumentAdapter から移植、区間計測付き）

struct SegmentTiming {
  var snapshot = 0.0
  var contextAlloc = 0.0
  var drawSetup = 0.0
  var drawPDF = 0.0
  var makeImage = 0.0
  var ciBuild = 0.0
  var ciRender = 0.0
  var total: Double {
    snapshot + contextAlloc + drawSetup + drawPDF + makeImage + ciBuild + ciRender
  }
}

final class RenderBench {
  let document: CGPDFDocument
  private static let maxScratchDimension = 1024
  private var scratchContext: CGContext?
  private(set) var scratchAllocationCount = 0

  init?(url: URL) {
    guard let doc = CGPDFDocument(url as CFURL) else { return nil }
    self.document = doc
  }

  var pageCount: Int { document.numberOfPages }

  private func reusableContext(width: Int, height: Int) -> CGContext? {
    if width > Self.maxScratchDimension || height > Self.maxScratchDimension {
      scratchAllocationCount += 1
      return CGContext.makeRGBAContext(width: width, height: height)
    }
    if let existing = scratchContext, existing.width == width, existing.height == height {
      return existing
    }
    guard let created = CGContext.makeRGBAContext(width: width, height: height) else { return nil }
    scratchAllocationCount += 1
    scratchContext = created
    return created
  }

  static func rotatedPageSize(box: CGRect, rotation: Int) -> CGSize {
    let r = ((rotation % 360) + 360) % 360
    switch r {
    case 90, 270: return CGSize(width: box.height, height: box.width)
    default: return CGSize(width: box.width, height: box.height)
    }
  }

  /// fullPageImageOnRenderQueue 相当。区間ごとに所要時間を計測して返す。
  func render(
    pageIndex: Int, scale: CGFloat, theme: ReaderColorTheme
  ) -> (image: CGImage?, timing: SegmentTiming, pixelSize: CGSize) {
    var t = SegmentTiming()

    let snap = measure { () -> (CGRect, Int)? in
      guard let page = document.page(at: pageIndex + 1) else { return nil }
      return (page.getBoxRect(.cropBox), Int(page.rotationAngle))
    }
    t.snapshot = snap.ms
    guard let (pageBox, rotation) = snap.value else { return (nil, t, .zero) }

    let rotatedSize = Self.rotatedPageSize(box: pageBox, rotation: rotation)
    guard rotatedSize.width > 0, rotatedSize.height > 0 else { return (nil, t, .zero) }

    let renderScale = max(1, scale)
    let pixelWidth = max(1, Int(ceil(rotatedSize.width * renderScale)))
    let pixelHeight = max(1, Int(ceil(rotatedSize.height * renderScale)))
    let pageRect = CGRect(origin: .zero, size: rotatedSize)
    let pixelSize = CGSize(width: pixelWidth, height: pixelHeight)

    let ctxResult = measure { () -> (CGPDFPage, CGContext)? in
      guard let page = self.document.page(at: pageIndex + 1),
        let context = self.reusableContext(width: pixelWidth, height: pixelHeight)
      else { return nil }
      return (page, context)
    }
    t.contextAlloc = ctxResult.ms
    guard let (page, context) = ctxResult.value else { return (nil, t, pixelSize) }

    context.saveGState()
    defer { context.restoreGState() }

    let setup = measure {
      context.clear(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
      context.setAllowsAntialiasing(true)
      context.setShouldAntialias(true)
      context.interpolationQuality = .high
      context.scaleBy(x: renderScale, y: renderScale)
      context.translateBy(x: 0, y: pageRect.height)
      context.scaleBy(x: 1, y: -1)
      let transform = page.getDrawingTransform(
        .cropBox, rect: pageRect, rotate: 0, preserveAspectRatio: true)
      context.concatenate(transform)
      context.setFillColor(gray: 1, alpha: 1)
      context.fill(page.getBoxRect(.cropBox))
    }
    t.drawSetup = setup.ms

    let draw = measure { context.drawPDFPage(page) }
    t.drawPDF = draw.ms

    let img = measure { context.makeImage() }
    t.makeImage = img.ms
    guard let baseImage = img.value else { return (nil, t, pixelSize) }

    let themed = theme.applyTimed(to: baseImage)
    t.ciBuild = themed.ciBuildMs
    t.ciRender = themed.renderMs

    return (themed.image, t, pixelSize)
  }
}

// MARK: - Bench driver

let benchDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let pdfsDir = benchDir.appendingPathComponent("pdfs")

let pdfFiles: [String]
if CommandLine.arguments.count > 1 {
  pdfFiles = Array(CommandLine.arguments.dropFirst())
} else {
  pdfFiles = ["accessibility.pdf", "illustration.pdf", "softwaredesign.pdf"]
}

// 実機相当: iPhone 15 Pro 縦持ちリーダー（393×852pt）× screenScale 3
let viewBounds = CGRect(x: 0, y: 0, width: 393, height: 852)
let screenScale: CGFloat = 3
let warmIterations = 5

print("=== Bookil render-bench ===")
print(
  "viewBounds=\(Int(viewBounds.width))x\(Int(viewBounds.height))pt  screenScale=\(Int(screenScale))  warmIter=\(warmIterations)"
)
print("")

for file in pdfFiles {
  let url = pdfsDir.appendingPathComponent(file)
  guard let bench = RenderBench(url: url) else {
    print("!! load failed: \(file)")
    continue
  }
  let count = bench.pageCount
  // 文書全体に散らしてサンプル（先頭/1-4/中央/3-4/末尾、最大5ページ）。
  let candidates = [0, count / 4, count / 2, (count * 3) / 4, count - 1]
  var seen = Set<Int>()
  let samplePages = candidates.filter { $0 >= 0 && $0 < count && seen.insert($0).inserted }

  print("──────────────────────────────────────────────────────────────")
  print("📕 \(file)  (pages=\(count), sampling \(samplePages.count): \(samplePages))")
  print("──────────────────────────────────────────────────────────────")

  for theme in ReaderColorTheme.allCases {
    var coldTotals: [Double] = []
    var warmSegments: [SegmentTiming] = []
    var pixelInfo = ""

    for pageIndex in samplePages {
      let page = bench.document.page(at: pageIndex + 1)
      let box = page?.getBoxRect(.cropBox) ?? .zero
      let rotation = Int(page?.rotationAngle ?? 0)
      let scale = PDFPageRenderScalePolicy.targetScale(
        pageBox: box, rotation: rotation, viewBounds: viewBounds, screenScale: screenScale)

      // cold: 各ページ初回（CIContext/GPU 起動を含むのは最初の1回のみだが、
      // scratch 再確保などページ依存の初回コストも拾う）。
      let cold = bench.render(pageIndex: pageIndex, scale: scale, theme: theme)
      coldTotals.append(cold.timing.total)
      if pixelInfo.isEmpty {
        pixelInfo = "\(Int(cold.pixelSize.width))x\(Int(cold.pixelSize.height))px"
      }

      // warm: 同一ページを複数回回して各区間の中央値を取る。
      var snaps: [SegmentTiming] = []
      for _ in 0..<warmIterations {
        snaps.append(bench.render(pageIndex: pageIndex, scale: scale, theme: theme).timing)
      }
      var agg = SegmentTiming()
      agg.snapshot = median(snaps.map { $0.snapshot })
      agg.contextAlloc = median(snaps.map { $0.contextAlloc })
      agg.drawSetup = median(snaps.map { $0.drawSetup })
      agg.drawPDF = median(snaps.map { $0.drawPDF })
      agg.makeImage = median(snaps.map { $0.makeImage })
      agg.ciBuild = median(snaps.map { $0.ciBuild })
      agg.ciRender = median(snaps.map { $0.ciRender })
      warmSegments.append(agg)
    }

    // テーマごとに全サンプルページの warm 区間中央値を平均。
    func avg(_ kp: (SegmentTiming) -> Double) -> Double {
      warmSegments.isEmpty ? 0 : warmSegments.map(kp).reduce(0, +) / Double(warmSegments.count)
    }
    let warmTotal = avg { $0.total }
    let coldMedian = median(coldTotals)

    print(
      String(
        format: "  [%-5@] cold(初回)=%.1fms  warm=%.1fms  (%@)",
        theme.rawValue as NSString, coldMedian, warmTotal, pixelInfo as NSString))
    print(
      String(
        format:
          "         snapshot=%.2f  ctxAlloc=%.2f  drawSetup=%.2f  drawPDF=%.2f  makeImage=%.2f  ciBuild=%.2f  ciRender=%.2f",
        avg { $0.snapshot }, avg { $0.contextAlloc }, avg { $0.drawSetup },
        avg { $0.drawPDF }, avg { $0.makeImage }, avg { $0.ciBuild }, avg { $0.ciRender }))
  }
  print("  scratch allocations: \(bench.scratchAllocationCount)")
  print("")
}

print("=== done ===")
