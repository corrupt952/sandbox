# swift-dave-poc

Minimal Swift wrapper around Discord's [libdave](https://github.com/discord/libdave)
C API (DAVE — Discord Audio/Video Encryption, an MLS-based E2EE protocol for
voice/video). `main.swift` creates a session, initializes it, reads back the
protocol version, and tears it down — just enough to confirm the C API links
and calls correctly from Swift via a `systemLibrary` module map.

## Files

- `Package.swift` — defines a `CLibDave` system library target (the C header)
  and a `DavePoC` executable that links against it.
- `Sources/CLibDave/dave.h` — the DAVE C API header, copied verbatim from
  Discord's [libdave](https://github.com/discord/libdave) (MIT licensed).
- `Sources/CLibDave/module.modulemap` — exposes `dave.h` to Swift and links `libdave`.
- `Sources/DavePoC/main.swift` — the PoC itself.

## Building (requires libdave separately)

`libdave`'s C++ build (and its vcpkg dependency tree — several hundred MB of
BoringSSL, MLS++, etc.) is intentionally **not** vendored here. To actually
link and run this PoC:

```sh
git clone https://github.com/discord/libdave ../libdave
cd ../libdave/cpp
# follow libdave/cpp's own README to build via vcpkg (produces build/ and
# build/vcpkg_installed/arm64-osx/lib/ with libdave.a and its dependencies)
cd -
swift build   # links against ../libdave/cpp/build via the paths in Package.swift
swift run DavePoC
```

Without the sibling `libdave` checkout, `swift build` compiles `main.swift`
successfully but fails at the link step (`ld: library 'dave' not found`) —
confirmed in this repo's current state.
