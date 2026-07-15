.PHONY: public-api-boundary

# Expected to fail: the module resolves, but its API is unavailable on macOS 26.
public-api-boundary:
	xcrun swiftc \
		-module-cache-path /tmp/wifi-aware-swift-module-cache \
		-typecheck probes/public-api-availability.swift
