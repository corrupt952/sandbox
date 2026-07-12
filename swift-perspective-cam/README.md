# swift-perspective-cam

PerspectiveCam prototype (step 1: correction preview only).

First step toward a "capture a region of another camera's input, flatten it into
a plane, and expose it as a virtual camera" idea. This step has **no virtual
camera output yet**: it captures camera frames with AVFoundation, lets you drag
the four corners of a region, and applies `CIPerspectiveCorrection` in real
time — a proof-of-concept for the correction pipeline.

No external libraries; Apple frameworks only (AVFoundation / Core Image / SwiftUI).

## Files

- `PerspectiveCamApp.swift` — app entry point
- `ContentView.swift` — main UI (left: raw feed with draggable corners, right: corrected preview)
- `CameraManager.swift` — `AVCaptureSession` wrapper: device discovery, switching, frame capture
- `PerspectiveCorrector.swift` — thin wrapper around the `CIPerspectiveCorrection` filter
- `CIImage+NSImage.swift` — conversion helper for display

## Setup (Xcode)

1. In Xcode, **File > New > Project** → macOS tab → **App**
   (Interface: **SwiftUI**, Language: **Swift**, any product name, e.g. `PerspectiveCam`)
2. Replace the generated `ContentView.swift` and `*App.swift` with the files here
3. Drag & drop `CameraManager.swift` / `PerspectiveCorrector.swift` /
   `CIImage+NSImage.swift` into the project ("Copy items if needed" checked)
4. In the **Info** tab, add `Privacy - Camera Usage Description`
   (`NSCameraUsageDescription`)
5. If **App Sandbox** is enabled under **Signing & Capabilities**, check
   **Camera** under Hardware (the permission request fails otherwise)
6. Build & run with `Cmd + R`

`build.sh` also compiles a standalone binary with `swiftc` for quick
verification, but it lacks `NSCameraUsageDescription`, so the runtime camera
permission request may fail — the Xcode project is the intended way to run.

## Usage

1. Allow camera access when prompted at launch
2. Pick a camera in the toolbar (built-in / external webcam / Continuity Camera)
3. Drag the four yellow handles on the raw feed (left pane) onto the corners of
   the region to flatten (a quadrilateral seen at an angle)
4. The corrected feed renders in the right pane in real time

## Coordinate systems (easy to trip over)

- SwiftUI/AppKit view coordinates: origin at top-left, Y grows downward
- Core Image (`CIImage`) coordinates: origin at bottom-left, Y grows upward
- `CIPerspectiveCorrection`'s `inputTopLeft` etc. must be given in Core Image
  coordinates, so `toCIImageSpace(_:)` in `ContentView.swift` applies
  `y' = imageHeight - y`

## Known limitations / future optimization

- Every frame renders via `CIContext.createCGImage` on each SwiftUI `body`
  evaluation — unoptimized (prototype priority). For real use, switch
  `CIContext` to a Metal backend and move rendering off the view update path.
- Available `AVCaptureDevice.DiscoverySession` device types vary by macOS
  version; some cameras may not appear depending on the environment.
- Thread safety is minimal; revisit before serious use.

## Next step

Once the correction logic is validated, implement virtual camera output with
`CMIOExtension`. Planned references:

- Apple, "Creating a camera extension with Core Media I/O"
- WWDC22, "Create camera extensions with Core Media IO"
- Halle Winkler's three-part CMIOExtension tutorial (theoffcuts.org)
- GitHub: `ldenoue/cameraextension` (minimal sample)
