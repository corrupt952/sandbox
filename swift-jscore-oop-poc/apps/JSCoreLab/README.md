# JSCoreLab

The app wrapper E11 needs. Everything measured in this POC so far is ad-hoc signed, and the remaining question is whether the `allow-jit` helper survives a real distribution path: Developer ID signing, notarization, stapling, and a first launch through Gatekeeper.

That question cannot be asked of a bare Mach-O. Notarization and stapling apply to a bundle, and in a real build the helper ships *inside* an app and is notarized as part of it — so the unit under test has to be the app. The helper itself does not change: it stays the plain executable the rest of this POC measures, and this app is somewhere for it to be signed and stapled from.

## Signing

`Config/Signing.xcconfig` is the project's base configuration on all four build configurations, and it carries an empty `DEVELOPMENT_TEAM` plus an `#include?` of `Signing.local.xcconfig`. The real team ID lives only in that local file, which the repository's root `.gitignore` covers (`**/Config/Signing.local.xcconfig`) — the same arrangement as `swift-bev/apps/BevLab` and `wifi-aware-lab/ios`.

Xcode bakes `DEVELOPMENT_TEAM` into `project.pbxproj` when it creates a project. It has been removed from there; check that it has not come back before committing:

```sh
grep -c DEVELOPMENT_TEAM JSCoreLab.xcodeproj/project.pbxproj   # expect 0
xcodebuild -project JSCoreLab.xcodeproj -showBuildSettings \
  -configuration Release | grep DEVELOPMENT_TEAM               # expect your team ID
```

Zero in the first and your team ID in the second means the value is coming from the local file rather than the project.

## How the helper gets in

App Sandbox and the hardened runtime are on the app target, and User Script Sandboxing is off — the Run Script below reaches outside the project and would be refused otherwise. That phase, last before the app is sealed, builds `PluginHelperDevID` with `swift build`, copies it to `Contents/MacOS/PluginHelper`, and signs it with `SandboxJIT.entitlements` — `app-sandbox` plus `allow-jit`, on the helper and not the app — using `--options runtime --timestamp`. The timestamp is what notarization later insists on.

`PluginHelperDevID` rather than `PluginHelper`: same source, symlinked, under its own `CFBundleIdentifier`. App Sandbox guards a container against a binary whose signing identity differs from the last one that used it, so a Developer ID helper sharing the ad-hoc variants' identifier trips a "differs from previously opened versions" dialog — in both directions. A separate identifier gives it a separate container.

## Exporting

```sh
./export.sh        # from apps/JSCoreLab; needs Xcode and the Developer ID certificate
```

Archives, exports with `method: developer-id`, and prints the helper's signature as archived and as exported, side by side, so a re-signing that dropped an entitlement would be visible rather than assumed. Xcode's export keeps everything — that was measured, not presumed. The output lands in `.build/devid/export/`, and `run.sh` picks the helper up from there for E11 when it exists.

`xcodebuild` writes logs under `~/Library`, which the Bash sandbox this was developed in refuses; run the script outside it.

## What E11 measures

Against the notarized and stapled app, with the probes that already exist:

1. Whether notarization accepts a bundle containing a helper with `allow-jit`.
2. Whether the JIT is still there afterwards — by the VM region tags, the way E5 does it, not by timing.
3. Whether the helper starts when the app arrives carrying a quarantine attribute and is launched through Gatekeeper.
4. What the first launch costs on that path. E10 established that the validation saving is keyed to the file itself and that a fresh copy pays about 90 ms; a real download adds Gatekeeper, which none of the local copies ever faced.
