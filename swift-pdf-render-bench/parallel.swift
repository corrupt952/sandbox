// parallel — 同じピクセル(同解像度・同品質)を、Apple純正フレームワーク(GCD + CoreGraphics)だけで
// 複数コア並列ラスタライズして速くできるかを実測する。サードパーティ不使用。
//
// 方式: 1ページを水平バンドに分割し、各バンドを concurrentPerform で並列描画。
//   - スレッドごとに別 CGPDFDocument を開く(rdar://19073954 の double-free 回避、調査で確認済み)
//   - 各バンドは full-size context に「そのバンドの device 行だけ」clip して drawPDFPage
//     → clip 外のラスタライズは CoreGraphics が省くので、バンド描画コスト ≒ 全体/バンド数 + 解釈
//   - 合成して単一スレッド描画とピクセル一致を検証
//
// 計測: 単一スレッド全描画 vs 並列N(=2,4,8) の wall-clock、合成オーバーヘッド、最大ピクセル差。
//
// ビルド: swiftc -O parallel.swift -o parallel
// 実行:   ./parallel

import CoreGraphics
import Dispatch
import Foundation

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

func makeCtx(_ pw: Int, _ ph: Int) -> CGContext? {
  CGContext(
    data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
}

func rotatedSize(_ box: CGRect, _ rot: Int) -> CGSize {
  let r = ((rot % 360) + 360) % 360
  return (r == 90 || r == 270) ? CGSize(width: box.height, height: box.width) : box.size
}

/// 1ページのジオメトリ(全 document 共通)。
struct PageGeom {
  let box: CGRect
  let rot: Int
  let size: CGSize
  let rs: CGFloat
  let pw: Int
  let ph: Int
}

func geom(_ doc: CGPDFDocument, _ pageIndex: Int, scale: CGFloat) -> PageGeom? {
  guard let page = doc.page(at: pageIndex + 1) else { return nil }
  let box = page.getBoxRect(.cropBox)
  let rot = Int(page.rotationAngle)
  let size = rotatedSize(box, rot)
  guard size.width > 0, size.height > 0 else { return nil }
  let rs = max(1, scale)
  return PageGeom(
    box: box, rot: rot, size: size, rs: rs,
    pw: max(1, Int(ceil(size.width * rs))), ph: max(1, Int(ceil(size.height * rs))))
}

/// context に「device 矩形 clipRect に clip して」ページを描画。clipRect=nil なら全面。
func drawPage(
  _ ctx: CGContext, _ doc: CGPDFDocument, _ pageIndex: Int, _ g: PageGeom, clip: CGRect?
) {
  guard let page = doc.page(at: pageIndex + 1) else { return }
  ctx.saveGState()
  if let clip { ctx.clip(to: clip) }
  let pageRect = CGRect(origin: .zero, size: g.size)
  ctx.setAllowsAntialiasing(true)
  ctx.setShouldAntialias(true)
  ctx.interpolationQuality = .high
  ctx.scaleBy(x: g.rs, y: g.rs)
  ctx.translateBy(x: 0, y: pageRect.height)
  ctx.scaleBy(x: 1, y: -1)
  ctx.concatenate(
    page.getDrawingTransform(.cropBox, rect: pageRect, rotate: 0, preserveAspectRatio: true))
  ctx.setFillColor(gray: 1, alpha: 1)
  ctx.fill(g.box)
  ctx.drawPDFPage(page)
  ctx.restoreGState()
}

func targetScale(_ doc: CGPDFDocument, _ pageIndex: Int, viewBounds: CGRect, screenScale: CGFloat)
  -> CGFloat
{
  guard let page = doc.page(at: pageIndex + 1) else { return 0 }
  let box = page.getBoxRect(.cropBox)
  let rot = ((Int(page.rotationAngle) % 360) + 360) % 360
  let rw = (rot == 90 || rot == 270) ? box.height : box.width
  let rh = (rot == 90 || rot == 270) ? box.width : box.height
  guard rw > 0, rh > 0 else { return 0 }
  let sb = viewBounds.isEmpty ? 1 : max(viewBounds.width / rw, viewBounds.height / rh)
  return min(max(1, sb), 4.0) * screenScale
}

func rgbaBytes(of image: CGImage) -> [UInt8]? {
  let w = image.width
  let h = image.height
  let rb = w * 4
  var bytes = [UInt8](repeating: 0, count: rb * h)
  guard
    let ctx = CGContext(
      data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: rb,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { return nil }
  ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
  return bytes
}
func maxRGBDiff(_ a: CGImage, _ b: CGImage) -> Int? {
  guard let pa = rgbaBytes(of: a), let pb = rgbaBytes(of: b), pa.count == pb.count else {
    return nil
  }
  var maxD = 0
  var i = 0
  while i < pa.count {
    for c in 0..<3 { maxD = max(maxD, abs(Int(pa[i + c]) - Int(pb[i + c]))) }
    i += 4
  }
  return maxD
}

// MARK: - Driver

let benchDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let pdfsDir = benchDir.appendingPathComponent("pdfs")
let pdfFiles = ["accessibility.pdf", "illustration.pdf", "softwaredesign.pdf"]
let viewBounds = CGRect(x: 0, y: 0, width: 393, height: 852)
let screenScale: CGFloat = 3
let WARM = 7
let MAXN = 8

print("=== parallel rasterization (Apple純正 GCD+CoreGraphics のみ) ===")
print(
  "viewBounds=393x852 screenScale=3, warm median of \(WARM), cores=\(ProcessInfo.processInfo.activeProcessorCount)\n"
)

for file in pdfFiles {
  let url = pdfsDir.appendingPathComponent(file) as CFURL
  // スレッドプール用に document を MAXN 個事前に開く(描画ごとの再オープンを避ける)。
  guard let docs = (0..<MAXN).map({ _ in CGPDFDocument(url) }) as? [CGPDFDocument],
    docs.count == MAXN
  else {
    print("!! load failed: \(file)")
    continue
  }
  let base = docs[0]
  let count = base.numberOfPages
  var seen = Set<Int>()
  let pages = [0, count / 4, count / 2, (count * 3) / 4, count - 1].filter {
    $0 >= 0 && $0 < count && seen.insert($0).inserted
  }
  print("📕 \(file) (pages=\(count), sampling \(pages))")

  for p in pages {
    let scale = targetScale(base, p, viewBounds: viewBounds, screenScale: screenScale)
    guard let g = geom(base, p, scale: scale) else { continue }

    // --- 単一スレッド全描画(baseline) ---
    let single = medianMs(WARM) {
      guard let ctx = makeCtx(g.pw, g.ph) else { return }
      ctx.clear(CGRect(x: 0, y: 0, width: g.pw, height: g.ph))
      drawPage(ctx, base, p, g, clip: nil)
      _ = ctx.makeImage()
    }
    guard let refCtx = makeCtx(g.pw, g.ph) else { continue }
    refCtx.clear(CGRect(x: 0, y: 0, width: g.pw, height: g.ph))
    drawPage(refCtx, base, p, g, clip: nil)
    let refImage = refCtx.makeImage()

    var line = String(format: "  p%-4d (%dx%d): single=%.1fms", p, g.pw, g.ph, single)

    for n in [2, 4, 8] {
      let bandH = (g.ph + n - 1) / n
      // バンド画像格納用。
      var rasterMs: [Double] = []
      var compMs: [Double] = []
      var diff = -1
      for _ in 0..<WARM {
        var bandImages = [CGImage?](repeating: nil, count: n)
        let r = measure {
          DispatchQueue.concurrentPerform(iterations: n) { b in
            let y0 = b * bandH
            let h = min(bandH, g.ph - y0)
            guard h > 0, let ctx = makeCtx(g.pw, g.ph) else { return }
            ctx.clear(CGRect(x: 0, y: 0, width: g.pw, height: g.ph))
            // device 矩形(下原点)でバンド行に clip。
            drawPage(ctx, docs[b], p, g, clip: CGRect(x: 0, y: y0, width: g.pw, height: h))
            bandImages[b] = ctx.makeImage()
          }
        }
        rasterMs.append(r.ms)
        // 合成(バンド画像を重ねる)。
        let c = measure { () -> CGImage? in
          guard let comp = makeCtx(g.pw, g.ph) else { return nil }
          comp.clear(CGRect(x: 0, y: 0, width: g.pw, height: g.ph))
          for img in bandImages {
            if let img { comp.draw(img, in: CGRect(x: 0, y: 0, width: g.pw, height: g.ph)) }
          }
          return comp.makeImage()
        }
        compMs.append(c.ms)
        if diff == -1, let refImage, let comp = c.value, let d = maxRGBDiff(refImage, comp) {
          diff = d
        }
      }
      let raster = median(rasterMs)
      let comp = median(compMs)
      let total = raster + comp
      line += String(
        format: "  | N=%d: raster=%.1f +comp=%.1f =%.1fms (%.2fx, diff=%d)",
        n, raster, comp, total, single / total, diff)
    }
    print(line)
  }
  print("")
}
print("=== done ===")
