# IPMCore

`IPMCore` is a standalone, headless-testable Swift package implementing the
**pure geometry** for inverse perspective mapping (IPM) / bird's-eye-view
(BEV) rectification.

This is stage **V1-0** of a larger BEV experiment. It has **no dependency on
ARKit, CoreImage, or UIKit** — only `simd` and Foundation — so it builds and
tests with plain `swift test` on macOS, without a device, a camera feed, or
Xcode project. A later stage will wrap this library in an ARKit app that
supplies live camera poses/intrinsics and feeds the resulting quad into a
CoreImage perspective-correction filter; this package only owns the math.

## Why pure geometry, isolated

Keeping the projection/homography math free of ARKit/CoreImage/UIKit means:

- It can be unit tested headlessly (CI, `swift test`, no simulator).
- The coordinate-convention assumptions (world/camera axes, image origin)
  are explicit and independently verifiable, rather than hidden behind
  framework calls.
- The later ARKit-integrated app becomes a thin adapter: read
  `ARCamera.transform` / `ARCamera.intrinsics` / `ARFrame` into this
  package's types, and read the resulting quad out to feed a CoreImage
  filter or SceneKit overlay.

## Public API

### `Homography`

```swift
public enum Homography {
    static func homography(from src: [SIMD2<Double>], to dst: [SIMD2<Double>]) -> simd_double3x3?
    static func apply(_ H: simd_double3x3, to p: SIMD2<Double>) -> SIMD2<Double>
}
```

- `homography(from:to:)` solves the 8-DOF Direct Linear Transform (DLT) from
  exactly 4 point correspondences (`h33` fixed to 1, solving the resulting
  8x8 linear system via Gaussian elimination with partial pivoting). Returns
  `nil` for degenerate input (e.g. collinear points).
- `apply(_:to:)` applies a homography with a proper projective (w) divide.
- The matrix inverse of a homography (e.g. for round-tripping image ↔
  ground) is just `simd_inverse(H)`.

### `PinholeCamera`

```swift
public struct PinholeCamera {
    var intrinsics: simd_double3x3
    var cameraTransform: simd_double4x4
    var imageSize: SIMD2<Double>

    init(intrinsics:cameraTransform:imageSize:)
    init(fx:fy:cx:cy:cameraTransform:imageSize:)

    func project(_ worldPoint: SIMD3<Double>) -> SIMD2<Double>?
}
```

World→image projection using the **ARKit convention**:

- Camera local space is right-handed: the camera looks down its local
  **-Z** axis, **+X** is right, **+Y** is up. This matches
  `ARCamera.transform` (a camera-to-world transform).
- World space is right-handed, **+Y up**, matching ARKit's world coordinate
  system.
- `project` transforms the world point into camera space via
  `simd_inverse(cameraTransform)`, discards points with camera-space
  `z >= 0` (on or behind the camera — forward is -Z, so visible points have
  negative z), converts into the frame the intrinsics expect (+X right, +Y
  **down**, +Z forward) by negating Y and Z, then perspective-divides by the
  positive depth and applies `intrinsics`. A point above the optical axis
  (camera +Y) therefore lands above the principal point (`v < cy`), matching
  the standard ARKit intrinsics / `ARCamera.projectPoint` convention.

### `GroundRect`

```swift
public struct GroundRect {
    var width: Double
    var depth: Double
    var center: SIMD3<Double>
    var forward: SIMD2<Double>

    var planeY: Double
    var worldCorners: [SIMD3<Double>]
}
```

A metric rectangle on the horizontal ground plane `y = planeY` (world +Y is
up), centered at `center` (only `x`/`z` used for placement), oriented by a
2D `forward` direction in the X/Z plane. `worldCorners` returns the 4
corners, as seen from above, in a **fixed order**:
`[topLeft, topRight, bottomRight, bottomLeft]`, where "top" is towards
`forward` and "right" is `forward` rotated -90° in the X/Z plane.

### `IPM`

```swift
public enum IPM {
    static func imageQuad(groundCorners: [SIMD3<Double>], camera: PinholeCamera) -> [SIMD2<Double>]?
    static func flipY(_ p: SIMD2<Double>, imageHeight: Double) -> SIMD2<Double>

    struct PerspectiveCorners {
        var topLeft, topRight, bottomRight, bottomLeft: SIMD2<Double>
    }
    static func flippedPerspectiveCorners(quad: [SIMD2<Double>], imageHeight: Double) -> PerspectiveCorners?

    static func mmPerPixel(outputPixels: Double, rectMeters: Double) -> Double
}
```

- `imageQuad(groundCorners:camera:)` projects 4 ground-plane world points
  through a `PinholeCamera`; returns `nil` if any corner is behind the
  camera.
- `flipY(_:imageHeight:)` converts between top-left-origin image coordinates
  (ARKit/UIKit convention, Y down) and bottom-left-origin coordinates (Core
  Image convention, Y up). It is its own inverse.
- `flippedPerspectiveCorners(quad:imageHeight:)` takes a
  `[topLeft, topRight, bottomRight, bottomLeft]` image quad (top-left
  origin) and returns Y-flipped, corner-labeled points ready to feed a
  Core-Image-style 4-point perspective-correction filter
  (`inputTopLeft`/`inputTopRight`/`inputBottomRight`/`inputBottomLeft`),
  without this package depending on CoreImage itself.
- `mmPerPixel(outputPixels:rectMeters:)` maps an output BEV resolution (in
  pixels, along one axis) and the real-world extent it represents (in
  meters, along the same axis) to millimeters-per-pixel, for downstream
  metric measurement/overlay work.

## Coordinate convention note (important for the ARKit integration stage)

This package assumes the **ARKit world/camera convention**:
world +Y up, right-handed; `cameraTransform` is a camera-to-world transform
where the camera looks down its local -Z axis. This mirrors
`ARCamera.transform` directly, so the intent is that the later ARKit app can
pass `ARCamera.transform` and `ARCamera.intrinsics` straight into
`PinholeCamera` with no conversion.

However, this package's `project(_:)` is a **from-scratch reimplementation**
of the pinhole projection math, not a call into ARKit. Before relying on it
in the on-device app, that app should **cross-check `PinholeCamera.project`
against ARKit's own
`ARCamera.projectPoint(_:orientation:viewportSize:)`** for a handful of
known world points, to confirm:

- The sign/axis convention (-Z forward, +Y up, and the Y-down flip applied
  before the intrinsics) matches what `ARCamera.transform` /
  `ARCamera.intrinsics` actually encode on-device.
- How `ARCamera.intrinsics` and `viewportSize`/`orientation` interact — in
  particular, `ARCamera.intrinsics` is defined relative to the camera's
  native sensor orientation (landscape), not the "portrait, top-left
  origin" convention this package's tests assume for `imageSize`. The app
  layer will likely need to rotate/adjust intrinsics or use
  `ARCamera.projectPoint` directly for orientation-correct results, and
  should treat this package's `project(_:)` as the "ground truth math to
  validate against" rather than a drop-in replacement for
  `ARCamera.projectPoint`.
- This package validates its own math independently (see
  `IPMRoundTripTests`), but does not and cannot validate that a live
  `ARCamera.transform`/`ARCamera.intrinsics` pair from a real device follows
  the same convention in practice — that check belongs to the future ARKit
  integration stage.

## Testing

```sh
swift test
```

All tests are headless (no ARKit/CoreImage/UIKit involved) and run on plain
macOS. Test coverage includes:

- `HomographyTests` — identity mapping, a known unit-square → quad mapping
  (with `H * H⁻¹ ≈ I` and forward/backward round-trip checks), and
  degenerate-input handling.
- `PinholeCameraTests` — principal-point projection, off-axis (X and Y)
  projection sanity checks against the pinhole formula, and behind-camera
  rejection.
- `GroundRectTests` — corner ordering and extents for a rectangle on the
  ground plane.
- `IPMRoundTripTests` — the key end-to-end check: build a tilted, elevated
  camera looking at a 3m×3m ground rectangle, project its 4 corners to get
  an image quad, solve the image→ground homography from those 4
  correspondences, then verify that projecting an *interior* ground point to
  image and mapping it back via the homography recovers the original (X, Z)
  to within `1e-6`. Also verifies the `mmPerPixel` metric scale for a chosen
  output resolution, and `flipY`/`flippedPerspectiveCorners` correctness.

## Non-goals / explicitly out of scope for this package

- No ARKit session handling, camera capture, or frame delivery.
- No CoreImage filter application (`CIPerspectiveTransform`, `CIFilter`,
  etc.) — this package only produces the point data such a filter would
  consume.
- No UIKit/SceneKit rendering or overlay code.
- No lens distortion modeling (this is a pure pinhole model).

These belong to the later ARKit-integrated app stage that wraps this
library.
