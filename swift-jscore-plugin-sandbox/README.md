# swift-jscore-plugin-sandbox

Explores running untrusted "plugin" scripts safely with `JavaScriptCore`:
per-instance VM isolation, a permission-gated host bridge, and a GitHub
Actions-style manifest for declaring capability grants.

## How it works

- **`JSEvaluator`** wraps one `JSVirtualMachine` + `JSContext` per plugin
  instance. `loadScript(_:)` parses the script once (it must assign
  `globalThis.transform = (raw, ctx) => result`); `tick(raw:)` calls
  `transform` repeatedly without re-parsing.
- **Host bridge** (`host.*`) is built per-instance based on granted
  capabilities — a capability not granted is simply absent from the
  `JSContext`, giving a language-level default-deny:
  - `host.log` / `host.now` / `host.locale` — always available
  - `host.fetch(url)` — only for hosts in an explicit allowlist
  - `host.state.get/set` — persists across ticks within one evaluator, gated
    by a `state` permission
  - `host.ai.respond(prompt)` / `host.ai.availability()` — on-device
    inference via Apple's `FoundationModels` (macOS 26+, Apple Intelligence),
    gated by an `ai` permission
- **Permission manifest** — `PluginManifest`/`PluginPermissions` decode a
  GitHub Actions-style `permissions:` block (per-scope grant levels, plus a
  host allowlist for network) into the flags `JSEvaluator` needs.
- **`IsolationDemo`** proves two evaluators can't see each other's
  `globalThis` or `host.state`, and that state persists across ticks within
  a single evaluator.

The SwiftUI app lets you edit the script and raw JSON input, toggle
capabilities (or load them from a manifest), tick once/100x/1000x with
timing, and run the isolation test.

## Requirements

macOS 26+ with Apple Intelligence enabled (for the `host.ai` capability;
everything else works without it).

## How to run

```sh
swift build
swift run JSCorePluginSandbox
```

Build verified in this repo.
