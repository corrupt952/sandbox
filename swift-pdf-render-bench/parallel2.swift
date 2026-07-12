// parallel2 — 並列 disjoint-band ラスタライズの改良版。
//   改良1: clip ではなく band-size context + device translate で描画 → clip境界AAが消え、ピクセル一致
//   改良2: 合成は band画像を最終bufferへ1回ずつ(=合計1枚分のblit)。前版のN枚フルサイズ重ね描きを排除
//   改良3: 解釈律速ページ検出のため N=1 と N=4/8 を並べ、min を採用できるよう全部出す
//
// Apple純正(GCD + CoreGraphics)のみ。スレッドごとに別 CGPDFDocument。
// ビルド: swiftc -O parallel2.swift -o parallel2 ; 実行: ./parallel2

import CoreGraphics
import Dispatch
import Foundation

@inline(__always) func nowSeconds() -> Double {
  var ts = timespec()
  clock_gettime(CLOCK_MONOTONIC, &ts)
  return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
}
@inline(__always) func measure<T>(_ b: () -> T) -> (value: T, ms: Double) {
  let s = nowSeconds()
  let v = b()
  return (v, (nowSeconds() - s) * 1000)
}
func median(_ xs: [Double]) -> Double {
  let s = xs.sorted()
  let m = s.count / 2
  return s.isEmpty ? 0 : (s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m])
}
func medianMs(_ n: Int, _ b: () -> Void) -> Double { median((0..<n).map { _ in measure(b).ms }) }

func makeCtx(_ pw: Int, _ ph: Int) -> CGContext? {
  CGContext(
    data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
}
func rotatedSize(_ box: CGRect, _ rot: Int) -> CGSize {
  let r = ((rot % 360) + 360) % 360
  return (r == 90 || r == 270) ? CGSize(width: box.height, height: box.width) : box.size
}
struct PageGeom {
  let box: CGRect
  let size: CGSize
  let rs: CGFloat
  let pw: Int
  let ph: Int
}
func geom(_ doc: CGPDFDocument, _ idx: Int, scale: CGFloat) -> PageGeom? {
  guard let page = doc.page(at: idx + 1) else { return nil }
  let box = page.getBoxRect(.cropBox)
  let size = rotatedSize(box, Int(page.rotationAngle))
  guard size.width > 0, size.height > 0 else { return nil }
  let rs = max(1, scale)
  return PageGeom(
    box: box, size: size, rs: rs,
    pw: max(1, Int(ceil(size.width * rs))), ph: max(1, Int(ceil(size.height * rs))))
}

/// device空間で y を -yOffset シフトしてからページ変換を適用し描画。
/// yOffset を変えると「ページのどの水平帯がこの context に写るか」が決まる。
func drawPageShifted(
  _ ctx: CGContext, _ doc: CGPDFDocument, _ idx: Int, _ g: PageGeom, yOffset: CGFloat
) {
  guard let page = doc.page(at: idx + 1) else { return }
  ctx.saveGState()
  ctx.translateBy(x: 0, y: -yOffset)  // device空間で帯位置をずらす
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
func drawFull(_ ctx: CGContext, _ doc: CGPDFDocument, _ idx: Int, _ g: PageGeom) {
  ctx.clear(CGRect(x: 0, y: 0, width: g.pw, height: g.ph))
  drawPageShifted(ctx, doc, idx, g, yOffset: 0)
}

func targetScale(_ doc: CGPDFDocument, _ idx: Int, _ vb: CGRect, _ ss: CGFloat) -> CGFloat {
  guard let page = doc.page(at: idx + 1) else { return 0 }
  let box = page.getBoxRect(.cropBox)
  let rot = ((Int(page.rotationAngle) % 360) + 360) % 360
  let rw = (rot == 90 || rot == 270) ? box.height : box.width
  let rh = (rot == 90 || rot == 270) ? box.width : box.height
  guard rw > 0, rh > 0 else { return 0 }
  let sb = vb.isEmpty ? 1 : max(vb.width / rw, vb.height / rh)
  return min(max(1, sb), 4.0) * ss
}
func rgba(_ image: CGImage) -> [UInt8]? {
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
func maxDiff(_ a: CGImage, _ b: CGImage) -> Int? {
  guard let pa = rgba(a), let pb = rgba(b), pa.count == pb.count else { return nil }
  var m = 0
  var i = 0
  while i < pa.count {
    for c in 0..<3 { m = max(m, abs(Int(pa[i + c]) - Int(pb[i + c]))) }
    i += 4
  }
  return m
}

/// band-size context 群で並列描画し、最終bufferへ合成して1枚にする。
func renderParallel(_ docs: [CGPDFDocument], _ idx: Int, _ g: PageGeom, _ n: Int) -> CGImage? {
  let bandH = (g.ph + n - 1) / n
  var bands = [CGImage?](repeating: nil, count: n)
  DispatchQueue.concurrentPerform(iterations: n) { b in
    let y0 = b * bandH
    let h = min(bandH, g.ph - y0)
    guard h > 0, let ctx = makeCtx(g.pw, h) else { return }
    ctx.clear(CGRect(x: 0, y: 0, width: g.pw, height: h))
    // この band context は device y [0,h) を表す。ページの device 帯 [y0, y0+h) を写すため y0 シフト。
    drawPageShifted(ctx, docs[b], idx, g, yOffset: CGFloat(y0))
    bands[b] = ctx.makeImage()
  }
  guard let final = makeCtx(g.pw, g.ph) else { return nil }
  final.clear(CGRect(x: 0, y: 0, width: g.pw, height: g.ph))
  for (b, img) in bands.enumerated() {
    guard let img else { continue }
    let y0 = b * bandH
    let h = min(bandH, g.ph - y0)
    final.draw(img, in: CGRect(x: 0, y: y0, width: g.pw, height: h))  // device y-up で帯位置へ
  }
  return final.makeImage()
}

let benchDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let pdfsDir = benchDir.appendingPathComponent("pdfs")
let pdfFiles = ["accessibility.pdf", "illustration.pdf", "softwaredesign.pdf"]
let vb = CGRect(x: 0, y: 0, width: 393, height: 852)
let ss: CGFloat = 3
let WARM = 7
let MAXN = 8

print("=== parallel2 (band-size context, memcpy-blit合成, ピクセル一致重視) ===")
print("warm median \(WARM), cores=\(ProcessInfo.processInfo.activeProcessorCount)\n")

for file in pdfFiles {
  let url = pdfsDir.appendingPathComponent(file) as CFURL
  guard let docs = (0..<MAXN).map({ _ in CGPDFDocument(url) }) as? [CGPDFDocument],
    docs.count == MAXN
  else {
    print("!! load failed \(file)")
    continue
  }
  let base = docs[0]
  let count = base.numberOfPages
  var seen = Set<Int>()
  let pages = [0, count / 4, count / 2, (count * 3) / 4, count - 1].filter {
    $0 >= 0 && $0 < count && seen.insert($0).inserted
  }
  print("📕 \(file) (pages=\(count))")
  for p in pages {
    let scale = targetScale(base, p, vb, ss)
    guard let g = geom(base, p, scale: scale) else { continue }
    let single = medianMs(WARM) {
      guard let ctx = makeCtx(g.pw, g.ph) else { return }
      drawFull(ctx, base, p, g)
      _ = ctx.makeImage()
    }
    guard let refCtx = makeCtx(g.pw, g.ph) else { continue }
    drawFull(refCtx, base, p, g)
    let ref = refCtx.makeImage()
    var line = String(format: "  p%-4d (%dx%d): single=%.1fms", p, g.pw, g.ph, single)
    for n in [2, 4, 8] {
      let t = medianMs(WARM) { _ = renderParallel(docs, p, g, n) }
      let d =
        (ref != nil) ? (renderParallel(docs, p, g, n).flatMap { maxDiff(ref!, $0) } ?? -1) : -1
      line += String(format: "  | N=%d:%.1fms(%.2fx,diff=%d)", n, t, single / t, d)
    }
    print(line)
  }
  print("")
}
print("=== done ===")
