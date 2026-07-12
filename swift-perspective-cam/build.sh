#!/bin/bash
set -euo pipefail

# .xcodeproj を持たないため swiftc で直接コンパイルするビルドスクリプト。
# 生成物は動作確認用の単体バイナリで、NSCameraUsageDescription を含まないため
# 実行時のカメラアクセス要求は失敗する可能性がある（本来の実行は Xcode プロジェクト経由を想定）。

cd "$(dirname "$0")"

BUILD_DIR="build"
OUTPUT="$BUILD_DIR/PerspectiveCam"
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"

mkdir -p "$BUILD_DIR"

swiftc \
  -sdk "$SDK_PATH" \
  -o "$OUTPUT" \
  PerspectiveCamApp.swift \
  ContentView.swift \
  CameraManager.swift \
  PerspectiveCorrector.swift \
  CIImage+NSImage.swift

echo "Built: $OUTPUT"
