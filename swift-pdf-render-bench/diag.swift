// diag — (1)並列バンドの不一致が「どこに・どれだけ」出るかを可視化、(2)解釈律速ページの倍率安定性を確認。
//   不一致: illustration p48(最悪 diff) で single vs 並列(band-size N=4) を比較。
//     - 行ごとの最大diffを出し、バンド境界行に集中するか(=継ぎ目)を判定
//     - diff閾値別ピクセル数・平均diff
//     - single.png / parallel.png / diff_amp.png を書き出し(目視用)
//   解釈律速: softwaredesign p150 を複数回計測して倍率がブレるか確認。
//
// ビルド: swiftc -O diag.swift -o diag ; 実行: ./diag

import CoreGraphics
import Dispatch
import Foundation
import ImageIO
import UniformTypeIdentifiers

@inline(__always) func nowSeconds() -> Double {
  var ts = timespec()
  clock_gettime(CLOCK_MONOTONIC, &ts)
  return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
}
@inline(__always) func ms(_ b: () -> Void) -> Double {
  let s = nowSeconds()
  b()
  return (nowSeconds() - s) * 1000
}
func median(_ xs: [Double]) -> Double {
  let s = xs.sorted()
  let m = s.count / 2
  return s.isEmpty ? 0 : (s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m])
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
struct PG {
  let box: CGRect
  let size: CGSize
  let rs: CGFloat
  let pw: Int
  let ph: Int
}
func geom(_ doc: CGPDFDocument, _ i: Int, _ scale: CGFloat) -> PG? {
  guard let p = doc.page(at: i + 1) else { return nil }
  let box = p.getBoxRect(.cropBox)
  let sz = rotatedSize(box, Int(p.rotationAngle))
  guard sz.width > 0, sz.height > 0 else { return nil }
  let rs = max(1, scale)
  return PG(
    box: box, size: sz, rs: rs, pw: max(1, Int(ceil(sz.width * rs))),
    ph: max(1, Int(ceil(sz.height * rs))))
}
func drawShifted(_ ctx: CGContext, _ doc: CGPDFDocument, _ i: Int, _ g: PG, _ yOff: CGFloat) {
  guard let page = doc.page(at: i + 1) else { return }
  ctx.saveGState()
  ctx.translateBy(x: 0, y: -yOff)
  let pr = CGRect(origin: .zero, size: g.size)
  ctx.setAllowsAntialiasing(true)
  ctx.setShouldAntialias(true)
  ctx.interpolationQuality = .high
  ctx.scaleBy(x: g.rs, y: g.rs)
  ctx.translateBy(x: 0, y: pr.height)
  ctx.scaleBy(x: 1, y: -1)
  ctx.concatenate(
    page.getDrawingTransform(.cropBox, rect: pr, rotate: 0, preserveAspectRatio: true))
  ctx.setFillColor(gray: 1, alpha: 1)
  ctx.fill(g.box)
  ctx.drawPDFPage(page)
  ctx.restoreGState()
}
func renderFull(_ doc: CGPDFDocument, _ i: Int, _ g: PG) -> CGImage? {
  guard let c = makeCtx(g.pw, g.ph) else { return nil }
  c.clear(CGRect(x: 0, y: 0, width: g.pw, height: g.ph))
  drawShifted(c, doc, i, g, 0)
  return c.makeImage()
}
func renderParallel(_ docs: [CGPDFDocument], _ i: Int, _ g: PG, _ n: Int) -> CGImage? {
  let bandH = (g.ph + n - 1) / n
  var bands = [CGImage?](repeating: nil, count: n)
  DispatchQueue.concurrentPerform(iterations: n) { b in
    let y0 = b * bandH
    let h = min(bandH, g.ph - y0)
    guard h > 0, let c = makeCtx(g.pw, h) else { return }
    c.clear(CGRect(x: 0, y: 0, width: g.pw, height: h))
    drawShifted(c, docs[b], i, g, CGFloat(y0))
    bands[b] = c.makeImage()
  }
  guard let f = makeCtx(g.pw, g.ph) else { return nil }
  f.clear(CGRect(x: 0, y: 0, width: g.pw, height: g.ph))
  for (b, img) in bands.enumerated() {
    if let img {
      let y0 = b * bandH
      f.draw(img, in: CGRect(x: 0, y: y0, width: g.pw, height: min(bandH, g.ph - y0)))
    }
  }
  return f.makeImage()
}
func rgba(_ image: CGImage) -> (b: [UInt8], w: Int, h: Int)? {
  let w = image.width
  let h = image.height
  let rb = w * 4
  var bytes = [UInt8](repeating: 0, count: rb * h)
  guard
    let c = CGContext(
      data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: rb,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { return nil }
  c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
  return (bytes, w, h)
}
func savePNG(_ image: CGImage, _ url: URL) {
  guard
    let dst = CGImageDestinationCreateWithURL(
      url as CFURL, UTType.png.identifier as CFString, 1, nil)
  else { return }
  CGImageDestinationAddImage(dst, image, nil)
  CGImageDestinationFinalize(dst)
}
func targetScale(_ doc: CGPDFDocument, _ i: Int, _ vb: CGRect, _ ss: CGFloat) -> CGFloat {
  guard let p = doc.page(at: i + 1) else { return 0 }
  let box = p.getBoxRect(.cropBox)
  let rot = ((Int(p.rotationAngle) % 360) + 360) % 360
  let rw = (rot == 90 || rot == 270) ? box.height : box.width
  let rh = (rot == 90 || rot == 270) ? box.width : box.height
  guard rw > 0, rh > 0 else { return 0 }
  return min(max(1, vb.isEmpty ? 1 : max(vb.width / rw, vb.height / rh)), 4.0) * ss
}

let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let pdfs = dir.appendingPathComponent("pdfs")
let vb = CGRect(x: 0, y: 0, width: 393, height: 852)
let ss: CGFloat = 3
let MAXN = 8

// ---------- (1) 不一致の可視化: illustration p48, N=4 ----------
print("=== (1) 不一致の所在: illustration.pdf p48, 並列 N=4 (band-size) ===")
let url = pdfs.appendingPathComponent("illustration.pdf") as CFURL
let docs = (0..<MAXN).compactMap { _ in CGPDFDocument(url) }
let p = 48
let n = 4
if docs.count == MAXN, let g = geom(docs[0], p, targetScale(docs[0], p, vb, ss)),
  let ref = renderFull(docs[0], p, g), let par = renderParallel(docs, p, g, n),
  let ra = rgba(ref), let pa = rgba(par), ra.b.count == pa.b.count
{
  let bandH = (g.ph + n - 1) / n
  let w = ra.w
  let h = ra.h
  // 行ごと最大diff
  var rowMax = [Int](repeating: 0, count: h)
  var cntGt1 = 0
  var cntGt8 = 0
  var cntGt32 = 0
  var sumDiff = 0
  var nDiff = 0
  var globalMax = 0
  for y in 0..<h {
    var rmax = 0
    for x in 0..<w {
      let o = (y * w + x) * 4
      var d = 0
      for c in 0..<3 { d = max(d, abs(Int(ra.b[o + c]) - Int(pa.b[o + c]))) }
      if d > 0 {
        sumDiff += d
        nDiff += 1
      }
      if d > 1 { cntGt1 += 1 }
      if d > 8 { cntGt8 += 1 }
      if d > 32 { cntGt32 += 1 }
      if d > rmax { rmax = d }
    }
    rowMax[y] = rmax
    globalMax = max(globalMax, rmax)
  }
  let total = w * h
  print(
    String(
      format: "  画像 %dx%d (=%d px), band高=%d px, 境界行 ≈ y=%d, %d, %d",
      w, h, total, bandH, bandH, 2 * bandH, 3 * bandH))
  print(
    String(
      format:
        "  最大diff=%d  diff>0:%d(%.3f%%)  diff>8:%d(%.4f%%)  diff>32:%d(%.5f%%)  平均diff(>0):%.1f",
      globalMax, nDiff, 100.0 * Double(nDiff) / Double(total), cntGt8,
      100.0 * Double(cntGt8) / Double(total),
      cntGt32, 100.0 * Double(cntGt32) / Double(total),
      nDiff > 0 ? Double(sumDiff) / Double(nDiff) : 0))
  // diff>8 の行が境界に集中するか: rowMax>8 の行を列挙(上位)
  let hotRows = (0..<h).filter { rowMax[$0] > 8 }
  print("  rowMax>8 の行数: \(hotRows.count) / \(h)")
  if !hotRows.isEmpty {
    let sample = hotRows.prefix(20).map { "\($0)(\(rowMax[$0]))" }.joined(separator: " ")
    print("  該当行(行番号(maxdiff))先頭20: \(sample)")
    // 境界±2行に入る割合
    let bounds = (1..<n).map { $0 * bandH }
    let nearBoundary = hotRows.filter { r in bounds.contains { abs(r - $0) <= 2 } }.count
    print(
      String(
        format: "  うちバンド境界±2行に入る割合: %d/%d (%.0f%%)", nearBoundary, hotRows.count,
        100.0 * Double(nearBoundary) / Double(hotRows.count)))
  }
  // 画像書き出し(目視用): single / parallel / diff増幅
  savePNG(ref, dir.appendingPathComponent("diag_single.png"))
  savePNG(par, dir.appendingPathComponent("diag_parallel.png"))
  // diff増幅画像
  if let dctx = makeCtx(w, h) {
    var out = [UInt8](repeating: 0, count: w * h * 4)
    for idx in 0..<(w * h) {
      let o = idx * 4
      var d = 0
      for c in 0..<3 { d = max(d, abs(Int(ra.b[o + c]) - Int(pa.b[o + c]))) }
      let v = UInt8(min(255, d * 6))
      out[o] = v
      out[o + 1] = v
      out[o + 2] = v
      out[o + 3] = 255
    }
    out.withUnsafeMutableBytes { raw in
      if let c2 = CGContext(
        data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let im = c2.makeImage()
      {
        savePNG(im, dir.appendingPathComponent("diag_diff_amp.png"))
      }
    }
    _ = dctx
  }
  print("  → diag_single.png / diag_parallel.png / diag_diff_amp.png 書き出し済(diff×6増幅)")
}

// ---------- (2) 解釈律速ページの倍率安定性: softwaredesign p150 ----------
print("\n=== (2) 解釈律速ページの安定性: softwaredesign.pdf p150 (5回試行) ===")
let url2 = pdfs.appendingPathComponent("softwaredesign.pdf") as CFURL
let docs2 = (0..<MAXN).compactMap { _ in CGPDFDocument(url2) }
let p2 = 150
if docs2.count == MAXN, let g2 = geom(docs2[0], p2, targetScale(docs2[0], p2, vb, ss)) {
  for trial in 1...5 {
    func med(_ body: () -> Void) -> Double { median((0..<7).map { _ in ms(body) }) }
    let single = med { _ = renderFull(docs2[0], p2, g2) }
    let n2 = med { _ = renderParallel(docs2, p2, g2, 2) }
    let n4 = med { _ = renderParallel(docs2, p2, g2, 4) }
    let n8 = med { _ = renderParallel(docs2, p2, g2, 8) }
    print(
      String(
        format: "  試行%d: single=%.1f  N=2 %.1f(%.2fx)  N=4 %.1f(%.2fx)  N=8 %.1f(%.2fx)",
        trial, single, n2, single / n2, n4, single / n4, n8, single / n8))
  }
}
print("\n=== done ===")
