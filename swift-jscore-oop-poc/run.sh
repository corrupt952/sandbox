#!/bin/bash
# Builds the host and helper, then signs three further copies of the helper so the
# measurements can separate App Sandbox, the hardened runtime, and the JIT
# entitlement from each other, and runs the experiments.
#
# Ad-hoc signing is enough for App Sandbox locally: the container identifier comes
# from the signing identifier below, and no provisioning profile is involved.
set -euo pipefail

cd "$(dirname "$0")"

BUILD_DIR=".build/release"
IDENTIFIER="dev.zuki.jscore-oop-helper"

swift build -c release

cp "${BUILD_DIR}/PluginHelper" "${BUILD_DIR}/PluginHelperSandboxed"
codesign --force --sign - \
  --identifier "${IDENTIFIER}" \
  --entitlements Sandbox.entitlements \
  "${BUILD_DIR}/PluginHelperSandboxed"

# Hardened runtime with allow-jit still withheld. Pairing this with the variant
# below is what separates "the hardened runtime costs performance" from "the
# entitlement does" — measured, they are not the same claim.
cp "${BUILD_DIR}/PluginHelper" "${BUILD_DIR}/PluginHelperHardened"
codesign --force --sign - \
  --identifier "${IDENTIFIER}.hardened" \
  --options runtime \
  --entitlements Sandbox.entitlements \
  "${BUILD_DIR}/PluginHelperHardened"

# The one variant that is allowed to compile: sandbox + hardened runtime + allow-jit.
cp "${BUILD_DIR}/PluginHelper" "${BUILD_DIR}/PluginHelperJIT"
codesign --force --sign - \
  --identifier "${IDENTIFIER}.jit" \
  --options runtime \
  --entitlements SandboxJIT.entitlements \
  "${BUILD_DIR}/PluginHelperJIT"

echo "signed helpers:"
codesign -d --entitlements - "${BUILD_DIR}/PluginHelperSandboxed" 2>&1 | sed 's/^/  /'
codesign -d -v "${BUILD_DIR}/PluginHelperHardened" 2>&1 | grep -i "flags" | sed 's/^/  /'
echo

exec "${BUILD_DIR}/OOPHost" \
  --helper "${BUILD_DIR}/PluginHelper" \
  --sandboxed-helper "${BUILD_DIR}/PluginHelperSandboxed" \
  --hardened-helper "${BUILD_DIR}/PluginHelperHardened" \
  --jit-helper "${BUILD_DIR}/PluginHelperJIT" \
  "$@"
