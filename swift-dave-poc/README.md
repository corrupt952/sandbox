# swift-dave-poc

Minimal Swift wrapper around Discord's [libdave](https://github.com/discord/libdave)
C API (DAVE — Discord Audio/Video Encryption, an MLS-based E2EE protocol for
voice/video). `main.swift` creates a session, initializes it, reads back the
protocol version, and tears it down — just enough to confirm the C API links
and calls correctly from Swift via a `systemLibrary` module map.

## Files

- `Package.swift` — defines a `CLibDave` system library target (the C header)
  and a `DavePoC` executable that links against it.
- `Sources/CLibDave/dave.h` — the DAVE C API header. **Not in this repository**;
  copy it out of your own libdave checkout as shown below.
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

# the C API header comes from that same checkout
cp ../libdave/cpp/includes/dave/dave.h Sources/CLibDave/dave.h

swift build   # links against ../libdave/cpp/build via the paths in Package.swift
swift run DavePoC
```

Without the copied header, `swift build` fails at the `CLibDave` module itself
(`header 'dave.h' not found`). With the header but without a built `libdave`,
`main.swift` compiles and the failure moves to the link step (`ld: library
'dave' not found`).

## Licensing

libdave is distributed under the [MIT License](https://github.com/discord/libdave/blob/main/LICENSE).
This repository does not redistribute any part of it: `dave.h` is a local build
input copied from the upstream revision you chose, ignored by git, and the
compiled library is never vendored either. Anyone distributing a binary built
from this PoC has to satisfy libdave's MIT notice requirement themselves, and
review the licenses of libdave's own dependencies (BoringSSL, MLS++, and the
rest of its vcpkg tree) while they are at it.

The Swift code here is original.

## Write-up

<a href="https://labee.jp/posts/discord-dave-swift-libdave-c-interop"><img src="https://labee.jp/og/posts/discord-dave-swift-libdave-c-interop.png" alt="DiscordのE2E暗号化DAVEをSwiftから使うためlibdaveのC APIを直接呼び出した" width="600"></a>
