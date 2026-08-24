# swift-libghostty-workspace-poc

Concept verification for a lightweight terminal app that embeds Ghostty directly and adds a thin multi-workspace layer without a PTY relay.

## Result

The concept works. `GhosttyPoC` opens a native macOS 26 window with a source-list sidebar, treats one directory as one workspace, and keeps a separate live Ghostty terminal surface for every workspace added during the current process.

The sidebar starts with the user's home directory. Its bottom-aligned `+` button opens a directory-only picker; selecting a workspace swaps the terminal on the right while preserving that workspace's PTY and shell state. Tabs, splits, removal, reordering, and persistence across launches are intentionally absent.

The manually verified path covers launch at 900×600, adding a directory, switching between live workspace terminals, returning to the original terminal, and mouse text selection. `swift build` also succeeds. Terminal color fidelity, polished IME behavior, clipboard integration, file listing, long-duration soak testing, and high-frequency-output benchmarking are outside this PoC.

## Why direct embedding

A previous Terminal+tmux setup became unreliable under long-running, high-frequency TUI output because a relay layer sat between the PTY and its host. The hypothesis here is that a complete Ghostty surface embedded directly can retain terminal responsiveness while a small native layer handles project switching.

The implementation therefore creates Ghostty surfaces directly and does not proxy PTY output. Each directory-backed workspace owns one cached `TerminalView`; the native split-view controller only changes which view is attached to the visible terminal container.

## Ghostty API status

This PoC uses `libghostty-internal`, not a supported public embedder API. Ghostty's own header says this API is tailored to its macOS app and is not designed for external use, so source compatibility is not promised.

The supported `libghostty-vt` C API exposes terminal state, VT parsing, input encoding, and render state for a custom renderer. It does not provide Ghostty's complete Metal surface, renderer, or PTY lifecycle, so moving this PoC to `libghostty-vt` would require implementing those layers rather than replacing the current calls one-for-one.

Using the internal API is intentional for this feasibility check because it is currently the only upstream route to the complete Ghostty terminal surface being evaluated. The local static library and C header must always come from the same pinned Ghostty revision.

Ghostty owns its render thread and `CVDisplayLink`. The host forwards Ghostty's runtime wakeup callback to `ghostty_app_tick` on the main thread, matching the official macOS host, and does not create another display link or call `ghostty_surface_draw` every frame.

## Requirements

- macOS 26 and Xcode 26
- Swift Package Manager
- Zig 0.16.0, pinned by `mise.toml`
- gettext, supplied by the optional Nix development shell
- A local checkout of `ghostty-org/ghostty`

## Prepare Ghostty

Ghostty's static library is roughly 270 MB and its internal header changes with the implementation, so neither file is tracked here. Build and copy both from one pinned upstream checkout:

```sh
git clone https://github.com/ghostty-org/ghostty /tmp/ghostty-src
cd /tmp/ghostty-src
git checkout <pinned-ghostty-revision>

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export PATH="/usr/bin:$PATH"
zig build -Doptimize=ReleaseFast -Demit-macos-app=false

cd <path-to-sandbox>/swift-libghostty-workspace-poc
mkdir -p Vendor/ghostty/lib
cp /tmp/ghostty-src/macos/GhosttyKit.xcframework/macos-arm64_x86_64/ghostty-internal.a \
  Vendor/ghostty/lib/libghostty.a
cp /tmp/ghostty-src/macos/GhosttyKit.xcframework/macos-arm64_x86_64/Headers/ghostty.h \
  Sources/CGhostty/ghostty.h
```

If the upstream build fails, check these known setup traps:

1. `libtool: error: unrecognised option: '-static'` means a GNU libtool is shadowing Apple's tool; put `/usr/bin` first in `PATH`.
2. `msgfmt: FileNotFound` means gettext is missing; `direnv` and `flake.nix` provide it.
3. Missing `kCVPixelFormatType_30RGB_r210` or `nmedit` usually means a Nix SDK replaced Xcode's SDK; set `DEVELOPER_DIR` as above and delete Ghostty's `.zig-cache` before rebuilding.

## Build and run

```sh
swift build
.build/debug/GhosttyPoC
```

## Licensing

Ghostty is distributed under the [MIT License](https://github.com/ghostty-org/ghostty/blob/main/LICENSE). This repository does not redistribute Ghostty's source header or compiled static library: both are ignored local build inputs produced from the user's chosen upstream revision. Anyone packaging or distributing a combined binary must independently satisfy Ghostty's MIT notice requirement and review the licenses of Ghostty's bundled dependencies.

The Swift host code in this directory is an original PoC written against Ghostty's official C header and macOS host behavior. No third-party terminal host implementation is vendored or used as a source-code dependency.

## References

- [Ghostty source](https://github.com/ghostty-org/ghostty)
- [Ghostty internal embedder header](https://github.com/ghostty-org/ghostty/blob/main/include/ghostty.h)
- [Ghostty macOS app host](https://github.com/ghostty-org/ghostty/blob/main/macos/Sources/Ghostty/Ghostty.App.swift)
- [libghostty is coming](https://mitchellh.com/writing/libghostty-is-coming)
- [cmux](https://github.com/manaflow-ai/cmux)
- [herdr](https://github.com/herdrdev/herdr)
- [terminal-browser](https://github.com/zenbu-labs/terminal-browser)
