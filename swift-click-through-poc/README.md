# swift-click-through-poc

Two approaches to a transparent, floating `NSPanel` with per-tab click-through:
clicks pass through the panel everywhere except when the cursor is over one of
four tabs, which then expand and become interactive.

## Files

- `ClickThroughPoC.swift` — v1: a `Timer` polls `NSEvent.mouseLocation` at
  30fps and toggles `panel.ignoresMouseEvents` based on a screen-coordinate
  hit test. Simple, but fixed-rate polling.
- `ClickThroughPoCv2.swift` — v2: event-driven hybrid. A global `NSEvent`
  monitor detects the cursor entering a tab while click-through is on;
  `NSTrackingArea` handles per-tab hover once the panel becomes interactive; a
  low-frequency (2fps) timer is a failsafe for edge cases the monitor misses.

## How to run

```sh
swiftc -framework Cocoa -framework SwiftUI -o ClickThroughPoC ClickThroughPoC.swift && ./ClickThroughPoC
swiftc -framework Cocoa -framework SwiftUI -o ClickThroughPoCv2 ClickThroughPoCv2.swift && ./ClickThroughPoCv2
```

A small floating panel with 4 colored tabs (Clock/Notes/Music/Tasks) appears
on the right edge of the main screen. Move the cursor near a tab to see it
expand and become clickable; move away and clicks pass through the panel to
whatever is behind it.
