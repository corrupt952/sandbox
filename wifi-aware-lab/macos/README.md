# macOS Wi-Fi Aware SDK boundary

This directory contains a public-SDK-only check for Wi-Fi Aware availability on macOS 26. It does not load private frameworks, call private selectors, reconstruct private Swift modules, modify system services, or request undocumented entitlements.

## Current finding

With the macOS 26 SDK, `import WiFiAware` resolves but API declarations such as `WACapabilities.supportedFeatures` are marked unavailable on macOS. The retained probe captures that supported-development boundary without attempting to bypass it.

Run the check with:

```sh
make public-api-boundary
```

The command is expected to fail during type checking with an availability diagnostic. A future macOS SDK that makes these declarations available will change that result and is the signal to resume the macOS-to-iOS interoperability test using public APIs.

The runnable reference implementation is in [`../ios/`](../ios/).
