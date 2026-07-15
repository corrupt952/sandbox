# iOS Wi-Fi Aware Lab

An iOS/iPadOS 26 reference peer for testing Wi-Fi Aware with documented Apple APIs.

## Requirements

- Xcode 26
- Two Wi-Fi Aware-capable devices running iOS/iPadOS 26
- A development team configured locally in `Config/Signing.local.xcconfig`

The app declares `_aware-lab._udp` as both a publishable and subscribable service. Application messages are JSON encoded into individual UDP datagrams.

## Run on devices

1. Copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig` and set `DEVELOPMENT_TEAM`. The local file is ignored by Git.
2. Open `wifi-aware-lab.xcodeproj`, select a physical iPhone or iPad, then build and run.
3. Confirm that the Experiment section shows `Supported` and `Publish + Subscribe`.
4. Use **Advertise publisher** on one device and **Pick publisher** on the other to complete the system pairing flow.
5. Start the publisher on one device and **Browse & connect** on the other.
6. Use **Ping all** and **Refresh metrics** to verify bidirectional traffic and inspect the link.

The publisher and subscriber network roles operate on paired devices. The pairing controls use Apple's system `DeviceDiscoveryUI`.

## Verified result

An iPhone and iPad successfully established incoming and outgoing connections and exchanged `hello`, `ping`, and `pong` messages in both directions. Observed RTT values were 22.39 ms on the iPhone and 13.75 ms on the iPad; these are single-session observations, not benchmark claims.

## Protocol

Each UDP datagram contains one JSON `LabMessage`:

- `version`: currently `1`
- `id`: message UUID
- `session`: eight-character app-session ID
- `kind`: `hello`, `ping`, or `pong`
- `sentAt`: Foundation JSON date representation
- `replyTo`: the ping UUID for a pong
- `payload`: optional diagnostic text

The app replies to every valid `ping` with `pong`, regardless of whether the connection was created by the publisher, browser, or system device picker. This keeps a future Android peer small and makes packet-level inspection straightforward.

## References

- [Building peer-to-peer apps](https://developer.apple.com/documentation/wifiaware/building-peer-to-peer-apps)
- [Adopting Wi-Fi Aware](https://developer.apple.com/documentation/wifiaware/adopting-wi-fi-aware)
- [Connect with Wi-Fi Aware](https://developer.apple.com/videos/play/wwdc2025/228/)
