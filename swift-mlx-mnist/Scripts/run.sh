#!/bin/bash
# Bare SwiftPM cannot compile the MLX Metal shaders (mlx-swift issue #36),
# so GPU runs need an xcodebuild-built binary plus DYLD_FRAMEWORK_PATH.
set -euo pipefail
cd "$(dirname "$0")/.."

# On the first build Xcode asks you to trust mlx-swift's Metal-shader build
# plugin. Approve it once (it is Apple's official plugin). We deliberately do
# NOT pass -skipPackagePluginValidation, which would auto-trust every plugin.
DERIVED=.build/xcodebuild
xcodebuild build \
  -scheme swift-mlx-mnist \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  -quiet

PRODUCTS="$DERIVED/Build/Products/Release"
DYLD_FRAMEWORK_PATH="$PRODUCTS" "$PRODUCTS/mnist-train" "$@"
