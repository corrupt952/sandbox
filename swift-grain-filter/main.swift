// GrainFilter — Paperman 風の単体スクリーンフィルタ（お試し / 単一ファイル）
//
// 2層構成（どちらも画面収録権限なし）:
//   1) content-blind な静的 pink(fBm) グレイン … 透明クリックスルー窓に重ねる
//   2) コントラスト低減 … ディスプレイのガンマLUT(CGSetDisplayTransferByTable)で
//      出力レンジを中央へ圧縮。値依存だが画面を読まない。色は不可侵(RGB等値)。
//
// 画面を「読まず・描く/変換するだけ」なので Screen Recording 権限は不要。
// 終了時・Off時にガンマは CGDisplayRestoreColorSyncSettings() で復元する。
//
// 実行:  swift main.swift
// ビルド: swiftc -O main.swift -o grainfilter && ./grainfilter
//
// 操作: メニューバー「▦ Grain」から Grain強度 / Contrast強度 / パターン再生成 / 終了。

import AppKit
import CoreGraphics

// MARK: - Noise (Bookil の FilmGrain pink を流用)

enum Noise {
  /// 4 オクターブ fBm（1/f 系）を [-1, 1] で返す。
  static func pink(_ x: Int, _ y: Int, _ seed: UInt64) -> Double {
    // 粒を細かくするため高周波寄りに（最細オクターブ = 1px）。
    let cellSizes = [8.0, 4.0, 2.0, 1.0]
    let fx = Double(x)
    let fy = Double(y)
    var sum = 0.0
    var amplitudeSum = 0.0
    for cell in cellSizes {
      let amplitude = cell  // 1/f 重み
      sum += amplitude * value(fx / cell, fy / cell, seed)
      amplitudeSum += amplitude
    }
    return (sum / amplitudeSum) * 2 - 1
  }

  private static func value(_ fx: Double, _ fy: Double, _ seed: UInt64) -> Double {
    let x0 = Int(floor(fx))
    let y0 = Int(floor(fy))
    let tx = fx - Double(x0)
    let ty = fy - Double(y0)
    let sx = tx * tx * (3 - 2 * tx)
    let sy = ty * ty * (3 - 2 * ty)
    let v00 = hash01(x0, y0, seed)
    let v10 = hash01(x0 + 1, y0, seed)
    let v01 = hash01(x0, y0 + 1, seed)
    let v11 = hash01(x0 + 1, y0 + 1, seed)
    let top = v00 + (v10 - v00) * sx
    let bottom = v01 + (v11 - v01) * sx
    return top + (bottom - top) * sy
  }

  private static func hash01(_ x: Int, _ y: Int, _ seed: UInt64) -> Double {
    var h = UInt64(truncatingIfNeeded: x) &* 0x9E37_79B9_7F4A_7C15
    h ^= UInt64(truncatingIfNeeded: y) &* 0xC2B2_AE3D_27D4_EB4F
    h ^= seed &* 0xD6E8_FEB8_6659_FD93
    h ^= h >> 29
    h = h &* 0xBF58_476D_1CE4_E5B9
    h ^= h >> 32
    return Double(h >> 40) / Double(UInt64(1) << 24)
  }

  /// 双極グレインのテクスチャを premultiplied RGBA で生成する。
  /// d>=0 は白（明るくする）、d<0 は黒（暗くする）を、|d| に比例した α で乗せる。
  static func makeImage(width: Int, height: Int, seed: UInt64, maxAlpha: Double = 0.5) -> CGImage? {
    guard width > 0, height > 0 else { return nil }
    let bytesPerRow = width * 4
    guard
      let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ),
      let buffer = ctx.data
    else {
      return nil
    }

    let px = buffer.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
    for y in 0..<height {
      let row = y * bytesPerRow
      for x in 0..<width {
        let d = pink(x, y, seed)
        let a = min(1.0, abs(d) * maxAlpha)
        let av = UInt8(a * 255)
        let i = row + x * 4
        if d >= 0 {
          px[i] = av
          px[i + 1] = av
          px[i + 2] = av
          px[i + 3] = av
        } else {
          px[i] = 0
          px[i + 1] = 0
          px[i + 2] = 0
          px[i + 3] = av
        }
      }
    }
    return ctx.makeImage()
  }
}

// MARK: - Contrast attenuation (ガンマLUT / 画面収録権限不要)

enum DisplayContrast {
  /// amount 0...1。出力 = v * (1 - amount)（ピーク=白を下げ、黒は0のまま）。
  /// 中間グレー中心の対称圧縮だと黒が浮いて画面が白くなり、眩しさも電力も増えるため、
  /// 「眩しさ低減＝総/ピーク輝度を下げる」目的に合わせてダウンワードなディミング曲線にする。
  /// 色は不可侵(RGB等値)。
  static func apply(amount: Double) {
    guard amount > 0.0001 else {
      restore()
      return
    }
    let n = 256
    var red = [CGGammaValue](repeating: 0, count: n)
    var green = [CGGammaValue](repeating: 0, count: n)
    var blue = [CGGammaValue](repeating: 0, count: n)
    let a = Float(amount)
    for i in 0..<n {
      let v = Float(i) / Float(n - 1)
      let out = max(0, min(1, v * (1 - a)))
      red[i] = out
      green[i] = out
      blue[i] = out
    }
    for display in activeDisplays() {
      CGSetDisplayTransferByTable(display, UInt32(n), &red, &green, &blue)
    }
  }

  static func restore() {
    CGDisplayRestoreColorSyncSettings()
  }

  private static func activeDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    guard count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
  }
}

// MARK: - Overlay View

final class GrainView: NSView {
  var image: CGImage?

  override var isFlipped: Bool { true }
  override var isOpaque: Bool { false }

  override func draw(_: NSRect) {
    guard let image, let ctx = NSGraphicsContext.current?.cgContext else { return }
    ctx.interpolationQuality = .none
    ctx.draw(image, in: bounds)
  }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
  private enum Group: Int {
    case grain = 1
    case contrast = 2
  }

  private var windows: [NSWindow] = []
  private var statusItem: NSStatusItem!
  private var seed: UInt64 = 0x1357_9BDF
  private var grainIntensity: CGFloat = 0.25  // window.alphaValue = グレイン全体強度
  private var contrastAmount: Double = 0.0  // ガンマLUTの圧縮量

  func applicationDidFinishLaunching(_: Notification) {
    setupStatusItem()
    rebuildWindows()
    DisplayContrast.apply(amount: contrastAmount)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(screensChanged),
      name: NSApplication.didChangeScreenParametersNotification,
      object: nil
    )
  }

  func applicationWillTerminate(_: Notification) {
    DisplayContrast.restore()
  }

  // MARK: Status item / menu

  private func setupStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.title = "▦ Grain"

    let menu = NSMenu()
    addHeader(menu, "Grain")
    addPresets(
      menu, group: .grain, action: #selector(selectGrain(_:)),
      presets: [("Off", 0.0), ("Light", 0.25), ("Medium", 0.4), ("Strong", 0.7)],
      current: Double(grainIntensity))

    menu.addItem(.separator())
    addHeader(menu, "Dim (glare)")
    addPresets(
      menu, group: .contrast, action: #selector(selectContrast(_:)),
      presets: [("Off", 0.0), ("Light", 0.15), ("Medium", 0.3), ("Strong", 0.5)],
      current: contrastAmount)

    menu.addItem(.separator())
    let regen = NSMenuItem(
      title: "Regenerate Pattern", action: #selector(regenerate), keyEquivalent: "r")
    regen.target = self
    menu.addItem(regen)
    menu.addItem(.separator())
    let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)
    statusItem.menu = menu
  }

  private func addHeader(_ menu: NSMenu, _ title: String) {
    let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    header.isEnabled = false
    menu.addItem(header)
  }

  private func addPresets(
    _ menu: NSMenu, group: Group, action: Selector,
    presets: [(String, Double)], current: Double
  ) {
    for (title, value) in presets {
      let item = NSMenuItem(title: "  " + title, action: action, keyEquivalent: "")
      item.target = self
      item.tag = group.rawValue
      item.representedObject = value
      item.state = (abs(value - current) < 0.001) ? .on : .off
      menu.addItem(item)
    }
  }

  private func refreshMenuStates() {
    for item in statusItem.menu?.items ?? [] {
      guard let value = item.representedObject as? Double else { continue }
      let current = (item.tag == Group.grain.rawValue) ? Double(grainIntensity) : contrastAmount
      item.state = (abs(value - current) < 0.001) ? .on : .off
    }
  }

  @objc private func selectGrain(_ sender: NSMenuItem) {
    guard let value = sender.representedObject as? Double else { return }
    grainIntensity = CGFloat(value)
    for window in windows {
      window.alphaValue = grainIntensity
      window.orderFrontRegardless()
    }
    refreshMenuStates()
  }

  @objc private func selectContrast(_ sender: NSMenuItem) {
    guard let value = sender.representedObject as? Double else { return }
    contrastAmount = value
    DisplayContrast.apply(amount: contrastAmount)
    refreshMenuStates()
  }

  @objc private func regenerate() {
    seed = UInt64.random(in: 1...UInt64.max)
    rebuildWindows()
  }

  @objc private func quit() {
    DisplayContrast.restore()
    NSApp.terminate(nil)
  }

  @objc private func screensChanged() {
    rebuildWindows()
    DisplayContrast.apply(amount: contrastAmount)
  }

  // MARK: Overlay windows

  private func rebuildWindows() {
    for window in windows {
      window.orderOut(nil)
    }
    windows.removeAll()

    for screen in NSScreen.screens {
      let frame = screen.frame
      let window = NSWindow(
        contentRect: frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
      )
      window.isOpaque = false
      window.backgroundColor = .clear
      window.hasShadow = false
      window.ignoresMouseEvents = true
      window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
      window.collectionBehavior = [
        .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
      ]
      window.alphaValue = grainIntensity

      let view = GrainView(frame: NSRect(origin: .zero, size: frame.size))
      // ネイティブ画素で生成し、point サイズの bounds に等倍マップ＝粒が泳がず細かい。
      let scale = screen.backingScaleFactor
      view.image = Noise.makeImage(
        width: Int(frame.width * scale),
        height: Int(frame.height * scale),
        seed: seed
      )
      window.contentView = view
      window.setFrame(frame, display: true)
      window.orderFrontRegardless()
      windows.append(window)
    }
  }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
