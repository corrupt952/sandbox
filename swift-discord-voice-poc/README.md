# swift-discord-voice-poc

A from-scratch Swift PoC that connects to a real Discord voice channel as a bot,
joins Discord's **DAVE** end-to-end encryption group (the MLS-based E2EE that Discord
made mandatory for voice/video in March 2026), and **receives, decrypts, and decodes
other participants' audio to per-speaker WAV files**.

It is the companion to [`swift-dave-poc`](../swift-dave-poc): that project proves the
[libdave](https://github.com/discord/libdave) C API links and calls from Swift; this
one drives the full voice path end to end.

## What it does

```
[main gateway]   Identify -> READY -> VoiceStateUpdate -> VOICE_SERVER_UPDATE
[voice gateway]  Hello(v8) -> Identify(max_dave=1) -> Ready -> UDP IP Discovery
                 -> SelectProtocol(aead_aes256_gcm_rtpsize) -> SessionDescription(secret_key)
[DAVE / MLS]     op25 ExternalSender -> op26 KeyPackage -> op27 Proposals /
                 op29 Commit / op30 Welcome -> group join (per-user key ratchet)
[audio]          UDP RTP -> transport decrypt (AES-256-GCM rtpsize) -> DAVE decrypt
                 -> Opus decode -> per-speaker WAV (48kHz mono)
```

The bot tracks channel membership (seeding from `GUILD_CREATE.voice_states`), maps
SSRC to user id from `op5 Speaking`, and writes one `output/<user_id>.wav` per speaker.

## Notes learned building this

- **Everything is Swift-native.** libdave's flat C API is reached via a `systemLibrary`
  module map (standard C interop, no experimental Swift/C++ interop). No py-cord /
  discord.js runtime is bundled.
- **Transport crypto is `aead_aes256_gcm_rtpsize`.** Chosen in SelectProtocol because
  CryptoKit supports AES-GCM natively; the mode you pick also applies to received media.
  (discord.js only implements XChaCha20, which CryptoKit lacks.)
- **rtpsize + header extension is the subtle part.** Received packets carry an RTP header
  extension (first byte `0x90`, X bit set). The AEAD's AAD is the base header **plus the
  4-byte extension preamble only** — the extension *values* are encrypted and must be
  stripped from the front of the plaintext. This is only visible in receive-side
  implementations (e.g. `discord-ext-voice-recv`), not in send-only libraries.
- **Leaving isn't a Remove proposal.** When the group drops to a single member, Discord
  sends `op24 PrepareEpoch(epoch=1)` to reset into a fresh epoch, so the DAVE init must be
  re-entrant (not a once-only guard), or the next join fails with "not for this epoch".
- **IP Discovery port is big-endian** (`readUInt16BE`). LE may still connect because the
  server routes by the actual UDP source address, but receiving needs the correct value.

## Prerequisites

Like [`swift-dave-poc`](../swift-dave-poc), the native dependencies are **not vendored**,
so this directory does **not** build standalone — you set up two things first:

1. **libdave** (its vcpkg tree pulls in BoringSSL, MLS++, etc. — several hundred MB).
   Build it as a sibling `../libdave`:
   ```sh
   git clone https://github.com/discord/libdave ../libdave
   cd ../libdave/cpp
   # follow libdave/cpp's README to build via vcpkg
   # (produces build/ and build/vcpkg_installed/arm64-osx/lib/ with libdave.a + deps)
   cd -
   ```
   `Package.swift` links against `../libdave/cpp/build`.

2. **libopus** for Opus decoding, provided by the Nix dev shell (`flake.nix`). SwiftPM's
   `systemLibrary(pkgConfig: "opus")` resolves it via `pkg-config`, so builds must run
   **inside the dev shell**.

3. **A Discord bot** (only needed to *run*, not to build): create an application at the
   Developer Portal, enable the `GUILD_VOICE_STATES` intent, invite it to your server.
   Copy `.env.example` to `.env` and fill in the token / guild id / voice channel id.

Without these, `swift build` behaves like `swift-dave-poc`: the Swift sources compile, but
the link step fails (`ld: library 'dave' not found`). Outside the Nix shell it fails
earlier still, at `pkg-config` resolution for `opus`.

## Build & run

```sh
nix develop            # or: direnv allow  (opus + pkg-config on PATH)
swift build            # links ../libdave/cpp/build; needs libopus from the shell
# join the target voice channel from a normal Discord client and speak
VOICE_POC_HOLD=90 swift run DiscordVoicePoC
afplay output/<your_user_id>.wav
```

`VOICE_POC_HOLD` (seconds, default 90) is how long the bot stays connected before it
leaves, writes the WAVs, and exits.

## Scope

Receive-only. Sending (the bot speaking back), 48k->16k resampling, and CI packaging of
the native dependencies are out of scope for this PoC.

## Licensing

`Sources/CLibDave/dave.h` is copied verbatim from Discord's
[libdave](https://github.com/discord/libdave) (MIT). Discord voice audio reception is an
undocumented area of the protocol; this is a technical experiment against a server you
control. Recording participants may carry consent/legal obligations depending on
jurisdiction — handle that before any real use.
