// experiments — 改善案を1案ずつ直列計測する（同時実行による相互汚染を避けるため 1案=1プロセス）
//
// 使い方:  ./experiments <mode>
//   mode = theme-vimage | theme-cgblend | lowres | interp | diskcache
//
// 各 mode は「現行方式 vs 提案方式」を同一ページ・同条件 warm で A/B 比較し、
// 速度（中央値）に加えてピクセル一致（max/mean 絶対差）も検証する。
//
// ビルド: swiftc -O experiments.swift -o experiments
// 実行例: for m in theme-vimage theme-cgblend lowres interp diskcache; do ./experiments $m; done

import Accelerate
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Timing

@inline(__always) func nowSeconds() -> Double {
  var ts = timespec()
  clock_gettime(CLOCK_MONOTONIC, &ts)
  return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
}
@inline(__always) func measure<T>(_ body: () -> T) -> (value: T, ms: Double) {
  let s = nowSeconds()
  let v = body()
  return (v, (nowSeconds() - s) * 1000)
}
func median(_ xs: [Double]) -> Double {
  guard !xs.isEmpty else { return 0 }
  let s = xs.sorted()
  let m = s.count / 2
  return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
}
func medianMs(_ n: Int, _ body: () -> Void) -> Double {
  median((0..<n).map { _ in measure(body).ms })
}

// MARK: - Pixel utilities（正しさ検証用）

/// CGImage を既知の RGBA8 バッファへ展開して返す。
func rgbaBytes(of image: CGImage) -> (bytes: [UInt8], width: Int, height: Int, rowBytes: Int)? {
  let w = image.width
  let h = image.height
  let rowBytes = w * 4
  var bytes = [UInt8](repeating: 0, count: rowBytes * h)
  guard
    let ctx = CGContext(
      data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: rowBytes,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { return nil }
  ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
  return (bytes, w, h, rowBytes)
}

/// 2つの CGImage の RGB チャンネル絶対差（max, mean）。サイズ不一致は nil。
func pixelDiff(_ a: CGImage, _ b: CGImage) -> (maxDiff: Int, meanDiff: Double)? {
  guard let pa = rgbaBytes(of: a), let pb = rgbaBytes(of: b),
    pa.width == pb.width, pa.height == pb.height
  else { return nil }
  var maxD = 0
  var sum = 0.0
  var n = 0
  let count = pa.bytes.count
  var i = 0
  while i < count {
    for c in 0..<3 {  // RGB のみ（alpha 無視）
      let d = abs(Int(pa.bytes[i + c]) - Int(pb.bytes[i + c]))
      if d > maxD { maxD = d }
      sum += Double(d)
      n += 1
    }
    i += 4
  }
  return (maxD, sum / Double(max(1, n)))
}

// MARK: - ReaderColorTheme（現行方式: CI 経由）

enum Theme { case off, night, sepia }

let sharedCIContext = CIContext()

/// 現行 apply(to:) 相当（CIColorInvert / CISepiaTone を createCGImage で焼く）。
func applyCI(_ theme: Theme, to image: CGImage) -> CGImage? {
  if theme == .off { return image }
  var ci = CIImage(cgImage: image)
  switch theme {
  case .off: break
  case .night: ci = ci.applyingFilter("CIColorInvert")
  case .sepia: ci = ci.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 1.0])
  }
  return sharedCIContext.createCGImage(ci, from: ci.extent)
}

// MARK: - Render path（drawPDFPage まで。makeImage 前の context を保持できる版）

struct DrawnContext {
  let context: CGContext
  let width: Int
  let height: Int
}

final class Renderer {
  let document: CGPDFDocument
  init?(url: URL) {
    guard let d = CGPDFDocument(url as CFURL) else { return nil }
    document = d
  }
  var pageCount: Int { document.numberOfPages }

  static func rotatedSize(_ box: CGRect, _ rot: Int) -> CGSize {
    let r = ((rot % 360) + 360) % 360
    return (r == 90 || r == 270) ? CGSize(width: box.height, height: box.width) : box.size
  }

  /// 新規 throwaway context に drawPDFPage まで実行して返す（makeImage はしない）。
  func drawInto(pageIndex: Int, scale: CGFloat, interpolation: CGInterpolationQuality = .high)
    -> DrawnContext?
  {
    guard let page = document.page(at: pageIndex + 1) else { return nil }
    let box = page.getBoxRect(.cropBox)
    let rot = Int(page.rotationAngle)
    let size = Self.rotatedSize(box, rot)
    guard size.width > 0, size.height > 0 else { return nil }
    let rs = max(1, scale)
    let pw = max(1, Int(ceil(size.width * rs)))
    let ph = max(1, Int(ceil(size.height * rs)))
    guard
      let ctx = CGContext(
        data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    let pageRect = CGRect(origin: .zero, size: size)
    ctx.clear(CGRect(x: 0, y: 0, width: pw, height: ph))
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = interpolation
    ctx.scaleBy(x: rs, y: rs)
    ctx.translateBy(x: 0, y: pageRect.height)
    ctx.scaleBy(x: 1, y: -1)
    ctx.concatenate(
      page.getDrawingTransform(.cropBox, rect: pageRect, rotate: 0, preserveAspectRatio: true))
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(box)
    ctx.drawPDFPage(page)
    return DrawnContext(context: ctx, width: pw, height: ph)
  }

  func targetScale(pageIndex: Int, viewBounds: CGRect, screenScale: CGFloat) -> CGFloat {
    guard let page = document.page(at: pageIndex + 1) else { return 0 }
    let box = page.getBoxRect(.cropBox)
    let rot = ((Int(page.rotationAngle) % 360) + 360) % 360
    let rw = (rot == 90 || rot == 270) ? box.height : box.width
    let rh = (rot == 90 || rot == 270) ? box.width : box.height
    guard rw > 0, rh > 0 else { return 0 }
    let sb = viewBounds.isEmpty ? 1 : max(viewBounds.width / rw, viewBounds.height / rh)
    return min(max(1, sb), 4.0) * screenScale
  }
}

// MARK: - vImage 変換（提案 T-1: context バッファ上で in-place）

/// night: RGB を 255-x に反転。byte 順 RGBA、alpha は恒等。in-place 可。
func vImageInvertInPlace(_ ctx: CGContext) {
  guard let data = ctx.data else { return }
  var buf = vImage_Buffer(
    data: data, height: vImagePixelCount(ctx.height), width: vImagePixelCount(ctx.width),
    rowBytes: ctx.bytesPerRow)
  var inv = (0...255).map { UInt8(255 - $0) }
  var idn = (0...255).map { UInt8($0) }
  // ARGB8888 命名だが実体は byte0..3 に table を適用。RGBA なので
  // alphaTable→R, redTable→G, greenTable→B, blueTable→A。RGB 反転・A 恒等。
  inv.withUnsafeBufferPointer { invP in
    idn.withUnsafeBufferPointer { idnP in
      _ = vImageTableLookUp_ARGB8888(
        &buf, &buf, invP.baseAddress, invP.baseAddress, invP.baseAddress, idnP.baseAddress,
        vImage_Flags(kvImageNoFlags))
    }
  }
}

/// sepia: 古典 sepia 行列を RGBA byte 順で適用（速度検証用。色は CISepiaTone と厳密一致しない）。
func vImageSepiaInPlace(_ ctx: CGContext) {
  guard let data = ctx.data else { return }
  var buf = vImage_Buffer(
    data: data, height: vImagePixelCount(ctx.height), width: vImagePixelCount(ctx.width),
    rowBytes: ctx.bytesPerRow)
  // 出力 byte0(R)=0.393R+0.769G+0.189B, byte1(G)=0.349R+0.686G+0.168B,
  // byte2(B)=0.272R+0.534G+0.131B, byte3(A)=A。divisor 256 の固定小数点。
  // 行優先 4x4（出力行 × 入力列, 列順 = R,G,B,A）。
  let div: Int32 = 256
  let m: [Int16] = [
    Int16(0.393 * 256), Int16(0.769 * 256), Int16(0.189 * 256), 0,
    Int16(0.349 * 256), Int16(0.686 * 256), Int16(0.168 * 256), 0,
    Int16(0.272 * 256), Int16(0.534 * 256), Int16(0.131 * 256), 0,
    0, 0, 0, 256,
  ]
  m.withUnsafeBufferPointer { mp in
    _ = vImageMatrixMultiply_ARGB8888(
      &buf, &buf, mp.baseAddress!, div, nil, nil, vImage_Flags(kvImageNoFlags))
  }
}

/// night: CGContext 上で .difference ブレンド + white fill により反転（提案 T-2）。
func cgBlendInvert(_ ctx: CGContext) {
  ctx.saveGState()
  ctx.setBlendMode(.difference)
  ctx.setFillColor(gray: 1, alpha: 1)
  ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
  ctx.restoreGState()
}

// MARK: - Sample setup

let benchDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let pdfsDir = benchDir.appendingPathComponent("pdfs")
let pdfFiles = ["accessibility.pdf", "illustration.pdf", "softwaredesign.pdf"]
let viewBounds = CGRect(x: 0, y: 0, width: 393, height: 852)
let screenScale: CGFloat = 3
let WARM = 7

struct Sample {
  let file: String
  let renderer: Renderer
  let pages: [Int]
}
func loadSamples() -> [Sample] {
  pdfFiles.compactMap { f in
    guard let r = Renderer(url: pdfsDir.appendingPathComponent(f)) else { return nil }
    let c = r.pageCount
    var seen = Set<Int>()
    let pages = [0, c / 4, c / 2, (c * 3) / 4, c - 1].filter {
      $0 >= 0 && $0 < c && seen.insert($0).inserted
    }
    return Sample(file: f, renderer: r, pages: pages)
  }
}

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "theme-vimage"
print("=== experiment: \(mode) ===  (warm median of \(WARM), 1800x2556px相当, Mac/AppleSilicon)\n")

switch mode {

// ───────────────────────────────────────────────────────────
// T-1: vImage in-place vs CI createCGImage
// ───────────────────────────────────────────────────────────
case "theme-vimage":
  for s in loadSamples() {
    print("📕 \(s.file)")
    for (label, theme) in [("night", Theme.night), ("sepia", Theme.sepia)] {
      var ciTimes: [Double] = []
      var viTimes: [Double] = []
      var maxDiffs: [Int] = []
      for p in s.pages {
        let scale = s.renderer.targetScale(
          pageIndex: p, viewBounds: viewBounds, screenScale: screenScale)
        // --- 現行: makeImage → CI filter createCGImage ---
        ciTimes.append(
          medianMs(WARM) {
            guard let dc = s.renderer.drawInto(pageIndex: p, scale: scale),
              let base = dc.context.makeImage()
            else { return }
            _ = applyCI(theme, to: base)
          })
        // --- 提案: drawPDF → vImage in-place → makeImage ---
        viTimes.append(
          medianMs(WARM) {
            guard let dc = s.renderer.drawInto(pageIndex: p, scale: scale) else { return }
            if theme == .night {
              vImageInvertInPlace(dc.context)
            } else {
              vImageSepiaInPlace(dc.context)
            }
            _ = dc.context.makeImage()
          })
        // --- 正しさ: vImage 出力 vs CI 出力（filter部分のみ比較）---
        if let dc1 = s.renderer.drawInto(pageIndex: p, scale: scale),
          let base = dc1.context.makeImage(),
          let ciOut = applyCI(theme, to: base),
          let dc2 = s.renderer.drawInto(pageIndex: p, scale: scale)
        {
          if theme == .night {
            vImageInvertInPlace(dc2.context)
          } else {
            vImageSepiaInPlace(dc2.context)
          }
          if let viOut = dc2.context.makeImage(), let d = pixelDiff(ciOut, viOut) {
            maxDiffs.append(d.maxDiff)
          }
        }
      }
      let ci = median(ciTimes)
      let vi = median(viTimes)
      let diff = maxDiffs.max() ?? -1
      let speedup = ci > 0 ? ci / vi : 0
      print(
        String(
          format: "  %-5@ : 現行(CI)=%.2fms  提案(vImage)=%.2fms  → %.2fx  | maxPixelDiff vs CI = %d",
          label as NSString, ci, vi, speedup, diff))
    }
    print("")
  }

// ───────────────────────────────────────────────────────────
// T-2: CGContext .difference invert vs CI invert (night)
// ───────────────────────────────────────────────────────────
case "theme-cgblend":
  for s in loadSamples() {
    print("📕 \(s.file)")
    var ciTimes: [Double] = []
    var cgTimes: [Double] = []
    var maxDiffs: [Int] = []
    for p in s.pages {
      let scale = s.renderer.targetScale(
        pageIndex: p, viewBounds: viewBounds, screenScale: screenScale)
      ciTimes.append(
        medianMs(WARM) {
          guard let dc = s.renderer.drawInto(pageIndex: p, scale: scale),
            let base = dc.context.makeImage()
          else { return }
          _ = applyCI(.night, to: base)
        })
      cgTimes.append(
        medianMs(WARM) {
          guard let dc = s.renderer.drawInto(pageIndex: p, scale: scale) else { return }
          cgBlendInvert(dc.context)
          _ = dc.context.makeImage()
        })
      if let dc1 = s.renderer.drawInto(pageIndex: p, scale: scale),
        let base = dc1.context.makeImage(),
        let ciOut = applyCI(.night, to: base),
        let dc2 = s.renderer.drawInto(pageIndex: p, scale: scale)
      {
        cgBlendInvert(dc2.context)
        if let cgOut = dc2.context.makeImage(), let d = pixelDiff(ciOut, cgOut) {
          maxDiffs.append(d.maxDiff)
        }
      }
    }
    print(
      String(
        format: "  night: 現行(CI)=%.2fms  提案(CGblend)=%.2fms  → %.2fx  | maxPixelDiff vs CI = %d",
        median(ciTimes), median(cgTimes), median(ciTimes) / median(cgTimes), maxDiffs.max() ?? -1))
    print("")
  }

// ───────────────────────────────────────────────────────────
// R-1: 2段描画 — full(×1.0) vs ×0.5 vs ×0.25 の合計描画時間
// ───────────────────────────────────────────────────────────
case "lowres":
  for s in loadSamples() {
    print("📕 \(s.file)")
    for (label, theme) in [("off", Theme.off), ("night", Theme.night)] {
      for factor in [1.0, 0.5, 0.25] {
        var times: [Double] = []
        var px = ""
        for p in s.pages {
          let full = s.renderer.targetScale(
            pageIndex: p, viewBounds: viewBounds, screenScale: screenScale)
          let scale = full * CGFloat(factor)
          times.append(
            medianMs(WARM) {
              guard let dc = s.renderer.drawInto(pageIndex: p, scale: scale) else { return }
              if theme == .night { vImageInvertInPlace(dc.context) }  // 提案フィルタ適用後の現実値
              _ = dc.context.makeImage()
            })
          if px.isEmpty, let dc = s.renderer.drawInto(pageIndex: p, scale: scale) {
            px = "\(dc.width)x\(dc.height)"
          }
        }
        print(
          String(
            format: "  %-5@ ×%.2f : %.2fms  (%@)", label as NSString, factor, median(times),
            px as NSString))
      }
    }
    print("")
  }

// ───────────────────────────────────────────────────────────
// R-2: interpolationQuality high vs default vs low
// ───────────────────────────────────────────────────────────
case "interp":
  for s in loadSamples() {
    print("📕 \(s.file)")
    var ref: CGImage?
    for (label, q) in [("high", CGInterpolationQuality.high), ("default", .default), ("low", .low)]
    {
      var times: [Double] = []
      var diffNote = ""
      for p in s.pages {
        let scale = s.renderer.targetScale(
          pageIndex: p, viewBounds: viewBounds, screenScale: screenScale)
        times.append(
          medianMs(WARM) {
            guard let dc = s.renderer.drawInto(pageIndex: p, scale: scale, interpolation: q) else {
              return
            }
            _ = dc.context.makeImage()
          })
      }
      // 1ページ目で high を基準にピクセル差を見る
      let p0 = s.pages[0]
      let scale0 = s.renderer.targetScale(
        pageIndex: p0, viewBounds: viewBounds, screenScale: screenScale)
      if let dc = s.renderer.drawInto(pageIndex: p0, scale: scale0, interpolation: q),
        let img = dc.context.makeImage()
      {
        if label == "high" {
          ref = img
        } else if let ref, let d = pixelDiff(ref, img) {
          diffNote = "  | vs high: max=\(d.maxDiff) mean=\(String(format: "%.2f", d.meanDiff))"
        }
      }
      print(
        String(format: "  %-7@ : %.2fms%@", label as NSString, median(times), diffNote as NSString))
    }
    print("")
  }

// ───────────────────────────────────────────────────────────
// C-1: ディスク永続（JPEG/HEIF encode→write→read→decode）
// ───────────────────────────────────────────────────────────
case "diskcache":
  let tmp = benchDir.appendingPathComponent("cache-test")
  try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
  for s in loadSamples() {
    print("📕 \(s.file)")
    let p = s.pages[0]
    let scale = s.renderer.targetScale(
      pageIndex: p, viewBounds: viewBounds, screenScale: screenScale)
    guard let dc = s.renderer.drawInto(pageIndex: p, scale: scale), let img = dc.context.makeImage()
    else { continue }
    let fullRender = medianMs(WARM) {
      guard let dc = s.renderer.drawInto(pageIndex: p, scale: scale) else { return }
      vImageInvertInPlace(dc.context)
      _ = dc.context.makeImage()
    }
    for (fmtLabel, utType, opts) in [
      ("JPEG q0.8", UTType.jpeg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary),
      ("HEIF q0.8", UTType.heic, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary),
    ] {
      let url = tmp.appendingPathComponent("p.\(utType.preferredFilenameExtension ?? "bin")")
      // encode + write
      var data: Data?
      let encMs = medianMs(3) {
        let m = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(m, utType.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, img, opts)
        CGImageDestinationFinalize(dest)
        data = m as Data
      }
      try? data?.write(to: url)
      let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
      // read + decode（OSページキャッシュに乗った warm 状態）
      let decMs = medianMs(WARM) {
        guard let d = try? Data(contentsOf: url),
          let src = CGImageSourceCreateWithData(d as CFData, nil),
          let decoded = CGImageSourceCreateImageAtIndex(
            src, 0,
            [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true]
              as CFDictionary)
        else { return }
        // 遅延デコードを排し実コストを測るため、実バッファへ展開させる。
        _ = decoded.dataProvider?.data
      }
      print(
        String(
          format: "  %-9@ : encode=%.2fms  read+decode=%.2fms  size=%dKB  (フル描画=%.2fms)",
          fmtLabel as NSString, encMs, decMs, (size ?? 0) / 1024, fullRender))
    }
    print("")
  }
  try? FileManager.default.removeItem(at: tmp)

// ───────────────────────────────────────────────────────────
// decompose: drawPDFPage の律速分解
//   time(ms) = a + b·megapixels を最小二乗で分離。
//   a = 解像度非依存の固定費（≒コンテンツストリーム解釈・グリフ生成）
//   b = 画素あたりラスタライズ係数（ms/MP）
//   → a が大きい文書 = 解釈律速（解像度を下げても消えない本質コスト）
//   → b が支配的な文書 = ラスタライズ律速（解像度に比例）
// ───────────────────────────────────────────────────────────
case "decompose":
  let factors: [CGFloat] = [0.25, 0.5, 1.0, 2.0]
  for s in loadSamples() {
    print("📕 \(s.file)")
    var aSum = 0.0
    var bSum = 0.0
    var n = 0
    for p in s.pages {
      let full = s.renderer.targetScale(
        pageIndex: p, viewBounds: viewBounds, screenScale: screenScale)
      var xs: [Double] = []  // megapixels
      var ys: [Double] = []  // ms
      var dims = ""
      for f in factors {
        let scale = full * f
        guard let probe = s.renderer.drawInto(pageIndex: p, scale: scale) else { continue }
        let mp = Double(probe.width * probe.height) / 1_000_000
        let ms = medianMs(WARM) {
          guard let dc = s.renderer.drawInto(pageIndex: p, scale: scale) else { return }
          _ = dc.context.makeImage()
        }
        xs.append(mp)
        ys.append(ms)
        if f == 1.0 { dims = "\(probe.width)x\(probe.height)" }
      }
      // 最小二乗 y = a + b x
      let m = Double(xs.count)
      let sx = xs.reduce(0, +)
      let sy = ys.reduce(0, +)
      let sxx = zip(xs, xs).map(*).reduce(0, +)
      let sxy = zip(xs, ys).map(*).reduce(0, +)
      let denom = m * sxx - sx * sx
      let b = denom != 0 ? (m * sxy - sx * sy) / denom : 0
      let a = (sy - b * sx) / m
      aSum += a
      bSum += b
      n += 1
      let series = zip(factors, ys).map { String(format: "×%.2f=%.1f", $0.0, $0.1) }.joined(
        separator: " ")
      print(
        String(
          format: "  p%-4d (%@): 固定費a=%.1fms  ラスタ係数b=%.1fms/MP  [%@]",
          p, dims as NSString, a, b, series as NSString))
    }
    let aAvg = aSum / Double(max(1, n))
    let bAvg = bSum / Double(max(1, n))
    // ×1.0 (full≈screenScale3) での内訳目安: full の MP は文書で異なるので代表 13.8MP(1800x2556≒4.6MP… 実際は3x)で算出せず、各ページ実測の平均比から提示
    print(String(format: "  ▶ 平均: 固定費a=%.1fms  ラスタ係数b=%.1fms/MP", aAvg, bAvg))
    print("")
  }

default:
  print("unknown mode: \(mode)")
  print("modes: theme-vimage | theme-cgblend | lowres | interp | diskcache | decompose")
}

print("=== \(mode) done ===")
