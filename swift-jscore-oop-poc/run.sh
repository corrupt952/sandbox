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

# The document-scope fixtures sit directly in the home directory, because a
# document-scoped bookmark may not point into a system location and the temporary
# directory resolves under /private. Nothing removes them if a run is interrupted
# before its cleanup, so clear any stragglers first. Concurrent runs are not a case
# this POC supports, so a blanket glob is fine.
rm -rf "${HOME}/jscore-e8-doc-"*

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

# Sandboxed, plus the two bookmark entitlements. Paired with PluginHelperSandboxed,
# this is what separates "the bookmark is bound to the process that made it" from
# "the helper was never entitled to use one" when E8's resolve fails.
cp "${BUILD_DIR}/PluginHelper" "${BUILD_DIR}/PluginHelperBookmark"
codesign --force --sign - \
  --identifier "${IDENTIFIER}.bookmark" \
  --entitlements SandboxBookmark.entitlements \
  "${BUILD_DIR}/PluginHelperBookmark"

# E8 needs a host that is itself sandboxed and carries the bookmark entitlements.
# It runs separately, because sandboxing the host would move every other baseline.
#
# The temporary exception is added here rather than committed: a sandboxed host
# cannot posix_spawn a helper outside its container, and the build directory's
# absolute path is machine-specific. It is read-only and scoped to that directory.
HOST_ENTITLEMENTS=".build/SandboxHost.generated.entitlements"
cp SandboxHost.entitlements "${HOST_ENTITLEMENTS}"
/usr/libexec/PlistBuddy \
  -c "Add :com.apple.security.temporary-exception.files.absolute-path.read-only array" \
  -c "Add :com.apple.security.temporary-exception.files.absolute-path.read-only:0 string ${PWD}/${BUILD_DIR}/" \
  "${HOST_ENTITLEMENTS}" > /dev/null

cp "${BUILD_DIR}/OOPHost" "${BUILD_DIR}/OOPHostSandboxed"
codesign --force --sign - \
  --identifier "dev.zuki.jscore-oop-host" \
  --entitlements "${HOST_ENTITLEMENTS}" \
  "${BUILD_DIR}/OOPHostSandboxed"

echo "signed helpers:"
codesign -d --entitlements - "${BUILD_DIR}/PluginHelperSandboxed" 2>&1 | sed 's/^/  /'
codesign -d -v "${BUILD_DIR}/PluginHelperHardened" 2>&1 | grep -i "flags" | sed 's/^/  /'
echo

# `|| status=$?` rather than plain invocation: under `set -e` a failing first pass
# would end the script before the second one ran, and E8 is worth having either way.
status=0
"${BUILD_DIR}/OOPHost" \
  --helper "${BUILD_DIR}/PluginHelper" \
  --sandboxed-helper "${BUILD_DIR}/PluginHelperSandboxed" \
  --bookmark-helper "${BUILD_DIR}/PluginHelperBookmark" \
  --stub-helper "${BUILD_DIR}/StubHelper" \
  --hardened-helper "${BUILD_DIR}/PluginHelperHardened" \
  --jit-helper "${BUILD_DIR}/PluginHelperJIT" \
  "$@" || status=$?

# Second pass: the same bookmark experiment with the host inside a sandbox of its
# own. Reported separately so the two host configurations stay distinguishable, and
# it does not decide the script's exit code — E8 is not a rejection criterion, so a
# failure here is a finding rather than a broken run.
#
# Absolute paths, unlike the first pass: App Sandbox redirects the host's working
# directory into its container, so a relative helper path resolves against the
# container and posix_spawn fails with ENOENT before the sandbox has an opinion.
echo
echo "════ E8 second pass — sandboxed host ════"
"${BUILD_DIR}/OOPHostSandboxed" \
  --only-bookmarks \
  --helper "${PWD}/${BUILD_DIR}/PluginHelper" \
  --sandboxed-helper "${PWD}/${BUILD_DIR}/PluginHelperSandboxed" \
  --bookmark-helper "${PWD}/${BUILD_DIR}/PluginHelperBookmark" \
  || echo "   (second pass exited $? — see above)"

# Third pass: the axis the second one cannot reach. A sandboxed process may not
# spawn a separately-contained child — the system aborts a child carrying any App
# Sandbox entitlement other than `inherit`, which is the SIGTRAP the second pass
# records — so the sandboxed minter and the sandboxed helper are run as siblings
# instead. The minter writes its blobs into its own container and exits; this
# unsandboxed orchestrator reads them out and hands them to a real sandboxed helper.
#
# The blobs land inside the minter's container because its exception for the build
# directory is read-only, so its container is the one place it can write. The
# orchestrator is unsandboxed, so reading them back out is nothing special.
HOST_CONTAINER="${HOME}/Library/Containers/dev.zuki.jscore-oop-host/Data"
BLOBS="${HOST_CONTAINER}/minted-blobs.json"
echo
echo "════ E8 third pass — sandboxed minter, unsandboxed orchestrator ════"
if "${BUILD_DIR}/OOPHostSandboxed" --mint-only "${BLOBS}"; then
  "${BUILD_DIR}/OOPHost" \
    --probe-blobs "${BLOBS}" \
    --sandboxed-helper "${PWD}/${BUILD_DIR}/PluginHelperSandboxed" \
    --bookmark-helper "${PWD}/${BUILD_DIR}/PluginHelperBookmark" \
    || echo "   (third pass exited $? — see above)"
else
  echo "   (minting pass exited $? — third pass skipped)"
fi

# Outside the branch: the minter leaves its fixtures behind on purpose, so the
# sibling can find what the blobs point at, and it leaves them behind just the same
# when it fails partway.
rm -rf "${HOST_CONTAINER}/tmp/jscore-oop-"*
rm -rf "${HOST_CONTAINER}/jscore-e8-doc-"*
rm -f "${BLOBS}"

exit $status
