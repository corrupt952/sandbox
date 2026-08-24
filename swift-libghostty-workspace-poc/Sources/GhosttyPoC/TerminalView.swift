import AppKit
import CGhostty

/// One Ghostty terminal surface hosted by an AppKit view.
final class TerminalView: NSView, NSTextInputClient {
  let workingDirectory: URL
  private var surface: ghostty_surface_t?

  private var markedText: String = ""
  private var keyTextAccumulator: String = ""
  private var insideKeyDown = false

  init(frame: NSRect, workingDirectory: URL) {
    self.workingDirectory = workingDirectory
    super.init(frame: frame)
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError("not supported") }

  deinit {
    if let s = surface { ghostty_surface_free(s) }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else {
      if let s = surface {
        ghostty_surface_set_focus(s, false)
        ghostty_surface_set_occlusion(s, false)
      }
      return
    }
    if surface == nil {
      let scale = window?.backingScaleFactor ?? 2.0
      surface = GhosttyBridge.shared.newSurface(
        nsView: self, scaleFactor: scale, workingDirectory: workingDirectory)
    }
    if let s = surface { ghostty_surface_set_occlusion(s, true) }
    syncSurfaceGeometry(to: bounds.size)
  }

  private func syncSurfaceGeometry(to pointSize: NSSize) {
    guard let s = surface, pointSize.width > 0, pointSize.height > 0 else { return }
    let scale = window?.backingScaleFactor ?? 2.0
    let w = UInt32(pointSize.width * scale)
    let h = UInt32(pointSize.height * scale)
    guard w > 0, h > 0 else { return }
    ghostty_surface_set_size(s, w, h)
    ghostty_surface_set_content_scale(s, scale, scale)
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    syncSurfaceGeometry(to: newSize)
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    syncSurfaceGeometry(to: bounds.size)
  }

  // MARK: - Focus

  override var acceptsFirstResponder: Bool { true }

  override func becomeFirstResponder() -> Bool {
    if let s = surface { ghostty_surface_set_focus(s, true) }
    return super.becomeFirstResponder()
  }

  override func resignFirstResponder() -> Bool {
    if let s = surface { ghostty_surface_set_focus(s, false) }
    return super.resignFirstResponder()
  }

  // MARK: - Keyboard input

  override func keyDown(with event: NSEvent) {
    guard let s = surface else {
      super.keyDown(with: event)
      return
    }

    // Route through NSTextInputClient first so IME composition and dead
    // keys work, then hand Ghostty one combined key event.
    let hadMarkedTextBefore = hasMarkedText()
    insideKeyDown = true
    keyTextAccumulator = ""
    interpretKeyEvents([event])
    let committedText = keyTextAccumulator
    keyTextAccumulator = ""
    insideKeyDown = false

    if hadMarkedTextBefore, committedText.isEmpty, !hasMarkedText() {
      return
    }

    let action: ghostty_input_action_e =
      event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
    let mods = modsFromEvent(event)
    let keycode = UInt32(event.keyCode)
    let unshifted: UInt32 =
      event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
    let composing = hasMarkedText()

    func send(_ cstr: UnsafePointer<CChar>?) {
      var input = ghostty_input_key_s()
      input.action = action
      input.mods = mods
      input.consumed_mods = GHOSTTY_MODS_NONE
      input.keycode = keycode
      input.text = cstr
      input.unshifted_codepoint = unshifted
      input.composing = composing
      _ = ghostty_surface_key(s, input)
    }

    if !committedText.isEmpty {
      committedText.withCString { send($0) }
    } else {
      send(nil)
    }
  }

  override func keyUp(with event: NSEvent) {
    guard let s = surface else { return }
    var input = ghostty_input_key_s()
    input.action = GHOSTTY_ACTION_RELEASE
    input.mods = modsFromEvent(event)
    input.consumed_mods = GHOSTTY_MODS_NONE
    input.keycode = UInt32(event.keyCode)
    input.text = nil
    input.unshifted_codepoint =
      event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
    input.composing = false
    _ = ghostty_surface_key(s, input)
  }

  override func doCommand(by selector: Selector) {
    // Non-text keys (Backspace/Arrow/Enter/...) already went through the
    // keycode path above; swallow AppKit's fallback so it doesn't beep.
  }

  private func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
    var raw: UInt32 = 0
    let flags = event.modifierFlags
    if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
    return ghostty_input_mods_e(rawValue: raw)
  }

  // MARK: - NSTextInputClient (minimal: only what keyDown above needs)

  func insertText(_ string: Any, replacementRange: NSRange) {
    guard insideKeyDown else { return }
    let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
    keyTextAccumulator += text
    markedText = ""
  }

  func setMarkedText(
    _ string: Any, selectedRange: NSRange, replacementRange: NSRange
  ) {
    markedText = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
  }

  func unmarkText() {
    markedText = ""
  }

  func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
  func markedRange() -> NSRange {
    markedText.isEmpty
      ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedText.count)
  }
  func hasMarkedText() -> Bool { !markedText.isEmpty }
  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
    -> NSAttributedString?
  { nil }
  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    window?.convertToScreen(convert(bounds, to: nil)) ?? .zero
  }
  func characterIndex(for point: NSPoint) -> Int { 0 }

  // MARK: - Mouse input (enough to scroll and click-to-focus)

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    guard let s = surface else { return }
    sendMousePosition(with: event, to: s)
    _ = ghostty_surface_mouse_button(
      s, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
  }

  override func mouseUp(with event: NSEvent) {
    guard let s = surface else { return }
    sendMousePosition(with: event, to: s)
    _ = ghostty_surface_mouse_button(
      s, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
  }

  override func mouseMoved(with event: NSEvent) {
    guard let s = surface else { return }
    sendMousePosition(with: event, to: s)
  }

  override func mouseDragged(with event: NSEvent) {
    guard let s = surface else { return }
    sendMousePosition(with: event, to: s)
  }

  private func sendMousePosition(with event: NSEvent, to surface: ghostty_surface_t) {
    let p = convert(event.locationInWindow, from: nil)
    ghostty_surface_mouse_pos(
      surface, Double(p.x), Double(bounds.height - p.y), modsFromEvent(event))
  }

  override func scrollWheel(with event: NSEvent) {
    guard let s = surface else { return }
    ghostty_surface_mouse_scroll(s, event.scrollingDeltaX, event.scrollingDeltaY, 0)
  }
}
