# swift-grain-filter

Menu-bar utility that overlays a static film-grain texture and/or dims the
display, without ever reading screen contents — so it needs no Screen
Recording permission.

## How it works

Two independent, content-blind layers:

1. **Grain** — a static pink-noise (fBm, 4 octaves) texture rendered once per
   screen and shown in a click-through, always-on-top borderless window at
   adjustable alpha. Pure procedural generation; nothing on screen is read.
2. **Dim (glare reduction)** — compresses each display's output range toward
   black via `CGSetDisplayTransferByTable` (a gamma LUT), restored with
   `CGDisplayRestoreColorSyncSettings()` on quit/off. Colors stay neutral
   (R=G=B at every LUT entry).

## How to run

```sh
swift main.swift
# or
swiftc -O main.swift -o grainfilter && ./grainfilter
```

Controls live in the menu bar under "▦ Grain": grain intensity presets,
dim intensity presets, pattern regeneration, and quit.
