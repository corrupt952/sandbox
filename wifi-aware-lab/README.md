# Wi-Fi Aware lab

Public-API experiments for Wi-Fi Aware / Neighbor Awareness Networking (NAN).

The repository contains an iOS/iPadOS reference app for discovery, pairing, bidirectional UDP messaging, and link metrics. It also contains a minimal macOS SDK boundary check. All runnable code is limited to documented Apple APIs; private frameworks, entitlement bypasses, runtime API reconstruction, and method swizzling are intentionally excluded.

## Platforms

- [`ios/`](ios/) — iOS/iPadOS app using the public `WiFiAware`, `Network`, and `DeviceDiscoveryUI` APIs.
- [`macos/`](macos/) — compile-time check showing the public API boundary on macOS 26.
- `android/` — Android Wi-Fi Aware interoperability probe (planned).

## Verified result

An iPhone and iPad running iOS/iPadOS 26 successfully paired, established publisher/subscriber connections, exchanged messages in both directions, and reported link metrics. On macOS 26, the `WiFiAware` module is present in the SDK but its API declarations are unavailable to macOS applications, so this repository does not claim or expose a supported macOS transport implementation.

The next macOS interoperability check should be repeated if a future macOS SDK publicly enables these declarations.
