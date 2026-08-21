import AppKit
import SwiftUI

/// A first-responder NSView that hands every key press to the session.
///
/// SwiftUI's `.focusable()` + `.onKeyPress` loses the editor to any button or
/// text field on the same screen, and backspace never arrives. An input method
/// has to own the keyboard while it is composing, so this takes the keys
/// directly instead.
struct KeyCatcher: NSViewRepresentable {
  var isFocused: Binding<Bool>
  var onKey: (NSEvent) -> Bool

  func makeNSView(context: Context) -> CaptureView {
    let view = CaptureView()
    view.onKey = onKey
    view.onFocusChange = { isFocused.wrappedValue = $0 }
    return view
  }

  func updateNSView(_ view: CaptureView, context: Context) {
    view.onKey = onKey
    view.onFocusChange = { isFocused.wrappedValue = $0 }
  }

  final class CaptureView: NSView {
    var onKey: ((NSEvent) -> Bool)?
    var onFocusChange: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard window != nil else { return }
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.window?.makeFirstResponder(self)
      }
    }

    override func mouseDown(with event: NSEvent) {
      window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
      if onKey?(event) == true { return }
      super.keyDown(with: event)
    }

    /// Swallow the system beep for keys we deliberately ignore while composing.
    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }

    override func becomeFirstResponder() -> Bool {
      onFocusChange?(true)
      return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
      onFocusChange?(false)
      return super.resignFirstResponder()
    }
  }
}

extension NSEvent {
  /// macOS virtual key codes for the keys an IME cares about.
  enum Code {
    static let returnKey: UInt16 = 36
    static let tab: UInt16 = 48
    static let space: UInt16 = 49
    static let delete: UInt16 = 51
    static let escape: UInt16 = 53
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
  }
}
