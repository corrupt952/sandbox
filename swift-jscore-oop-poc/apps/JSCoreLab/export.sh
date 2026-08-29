#!/bin/bash
# Archives JSCoreLab and exports it signed with Developer ID, then checks that the
# helper inside survived the round trip with its own entitlements intact.
#
# Kept apart from ../../run.sh on purpose: that script produces the ad-hoc variants
# E1–E10 measure, and this one needs a real certificate and Xcode. E11 consumes what
# this produces.
set -euo pipefail

cd "$(dirname "$0")"
POC_ROOT="$(cd ../.. && pwd)"
OUT="${POC_ROOT}/.build/devid"
ARCHIVE="${OUT}/JSCoreLab.xcarchive"
EXPORT="${OUT}/export"
OPTIONS="${OUT}/ExportOptions.generated.plist"

mkdir -p "${OUT}"
rm -rf "${ARCHIVE}" "${EXPORT}" "${OPTIONS}"

# The team ID lives only in the gitignored Signing.local.xcconfig, and Xcode resolves
# that #include? itself. Reading it back from the resolved build settings means the
# plist never has to be committed and nothing here parses xcconfig syntax.
TEAM_ID=$(xcodebuild -project JSCoreLab.xcodeproj -showBuildSettings -configuration Release 2>/dev/null \
  | awk '$1 == "DEVELOPMENT_TEAM" && $2 == "=" {print $3; exit}')
if [ -z "${TEAM_ID}" ]; then
  echo "no DEVELOPMENT_TEAM resolved — is Config/Signing.local.xcconfig in place?" >&2
  exit 1
fi

/usr/libexec/PlistBuddy \
  -c "Add :method string developer-id" \
  -c "Add :signingStyle string automatic" \
  -c "Add :teamID string ${TEAM_ID}" \
  -c "Add :destination string export" \
  "${OPTIONS}" > /dev/null

echo "── archive"
xcodebuild -project JSCoreLab.xcodeproj -scheme JSCoreLab -configuration Release \
  -archivePath "${ARCHIVE}" archive -quiet

echo "── export (Developer ID)"
xcodebuild -exportArchive -archivePath "${ARCHIVE}" \
  -exportOptionsPlist "${OPTIONS}" -exportPath "${EXPORT}" -quiet

# The point of the whole script. -exportArchive re-signs, and whether Xcode's
# re-signing keeps a nested executable's own entitlements is not something to
# assume — so the helper is inspected before and after, side by side.
ARCHIVED="${ARCHIVE}/Products/Applications/JSCoreLab.app/Contents/MacOS/PluginHelper"
EXPORTED="${EXPORT}/JSCoreLab.app/Contents/MacOS/PluginHelper"

inspect() {
  echo "   $1"
  codesign -dvvv "$2" 2>&1 | grep -E '^(Authority|Identifier|TeamIdentifier|Timestamp|CodeDirectory)' | sed 's/^/     /'
  echo "     entitlements:"
  codesign -d --entitlements :- "$2" 2>/dev/null | grep -oE 'com\.apple\.security\.[a-z.-]+' | sed 's/^/       /'
}

echo "── helper, archived vs exported"
inspect "archived (Apple Development expected)" "${ARCHIVED}"
inspect "exported (Developer ID expected)" "${EXPORTED}"

echo "── verification"
codesign --verify --deep --strict --verbose=2 "${EXPORT}/JSCoreLab.app" 2>&1 | sed 's/^/   /'

echo
echo "exported helper: ${EXPORTED}"
