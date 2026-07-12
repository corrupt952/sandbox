# DepthBEVCore

`DepthBEVCore` is a standalone, headless-testable Swift package implementing
the **pure geometry** for turning LiDAR depth-map pixels into a top-down
occupancy/height grid.

This is stage **V2-0** of the `swift-bev` experiment. It has **no dependency
on ARKit, CoreImage, UIKit, SceneKit, or Metal** — only `simd` and
Foundation — so it builds and tests with plain `swift test` on macOS,
without a device or an Xcode project. It also has **no dependency on
`IPMCore`**: the two pure-geometry stages are kept isolated from each other,
even though `DepthUnprojector` is deliberately the exact mathematical
inverse of `IPMCore.PinholeCamera.project(_:)`.

## Why pure geometry, isolated

Keeping the unprojection/binning math free of ARKit/CoreImage/SceneKit/Metal
means:

- It can be unit tested headlessly (CI, `swift test`, no simulator).
- The coordinate-convention assumptions (depth-map pixel origin, ARKit
  camera/world axes) are explicit and independently verifiable.
- A later ARKit-integrated app becomes a thin adapter: read
  `ARFrame.sceneDepth` (depth map + confidence map) and `ARCamera.transform`
  / `ARCamera.intrinsics` into this package's types, filter by confidence,
  and feed the resulting world points into `BEVGrid`.

## Public API

### `DepthUnprojector`

```swift
public struct DepthUnprojector {
    var intrinsics: simd_double3x3
    var cameraTransform: simd_double4x4
    var imageSize: SIMD2<Double>

    init(intrinsics:cameraTransform:imageSize:)
    init(fx:fy:cx:cy:cameraTransform:imageSize:)

    func cameraPoint(u: Double, v: Double, depth: Double) -> SIMD3<Double>
    func worldPoint(u: Double, v: Double, depth: Double) -> SIMD3<Double>
}
```

Turns a depth-map pixel `(u, v)` (top-left origin, `+v` down, matching the
raw ARKit depth buffer layout) plus a positive `depth` (meters in front of
the camera) into a world-space point, using the **ARKit convention**:

- `xn = (u - cx) / fx`, `yn = (v - cy) / fy` (the intrinsics act in the
  "vision" frame: +X right, +Y down, +Z forward).
- Vision-frame point `= (xn * depth, yn * depth, depth)`.
- ARKit camera-space point (`cameraPoint`, +X right, +Y up, -Z forward)
  `= (xn * depth, -yn * depth, -depth)` — negate Y and Z.
- World point (`worldPoint`) `= cameraTransform * cameraPoint`, where
  `cameraTransform` is the camera-to-world transform (the `ARCamera.transform`
  convention).

This is the **exact inverse** of `IPMCore.PinholeCamera.project(_:)`: project
a world point with `PinholeCamera`, then unproject the resulting pixel and
depth with `DepthUnprojector` using the same intrinsics/transform, and you
recover the original world point (see `DepthUnprojectorTests`'s round-trip
test, which re-derives the forward-projection math locally rather than
importing `IPMCore`, to keep the two packages isolated).

### `BEVGrid`

```swift
public struct BEVGrid {
    var origin: SIMD2<Double>
    var cellSize: Double
    var columns: Int
    var rows: Int
    var groundY: Double

    init(origin:cellSize:columns:rows:groundY:)

    func cellIndex(x: Double, z: Double) -> (column: Int, row: Int)?
    mutating func add(_ worldPoint: SIMD3<Double>)
    mutating func add(worldPoints: [SIMD3<Double>])

    func occupancy(column: Int, row: Int) -> Int
    func height(column: Int, row: Int) -> Double
    var occupancyGrid: [[Int]]
    var heightGrid: [[Double]]
}
```

A top-down occupancy/height grid over a metric `(X, Z)` region of the world
ground plane (`y = groundY`, world +Y up). `origin` is the world `(X, Z)` of
cell `(column: 0, row: 0)`; the grid extends `columns * cellSize` meters
along X and `rows * cellSize` meters along Z.

- `add(_:)` bins a world point into a cell by its `(X, Z)`, ignoring points
  outside the grid's extent. Each cell tracks a hit count (occupancy) and
  the max height above `groundY` seen (`worldPoint.y - groundY`, clamped at
  `>= 0`).
- Confidence filtering is intentionally **out of scope**: callers should
  skip low-confidence depth samples before calling `add(_:)`.

## Coordinate convention note (important for the ARKit integration stage)

Like `IPMCore`, this package assumes the ARKit world/camera convention:
world +Y up, right-handed; `cameraTransform` is a camera-to-world transform
where the camera looks down its local -Z axis. `DepthUnprojector` is written
so a later ARKit app can pass `ARFrame.sceneDepth.depthMap` samples,
`ARCamera.transform`, and `ARCamera.intrinsics` (adjusted for the depth
map's resolution) straight in, mirroring how `IPMCore.PinholeCamera` expects
the same inputs for projection.

As with `IPMCore`, this package's math is a from-scratch reimplementation,
not a call into ARKit — the future ARKit integration stage should
cross-check `DepthUnprojector.worldPoint` against known scene geometry (or
against `PinholeCamera.project` for round-trip consistency) before relying
on it on-device.

## Testing

```sh
swift test
```

All tests are headless and run on plain macOS. Test coverage includes:

- `DepthUnprojectorTests` — principal-point pixel unprojection, an
  off-principal pixel against the inverse-intrinsics formula, identity vs.
  non-identity `cameraTransform` handling, and a round-trip check against a
  locally re-derived pinhole projection (recovering the original pixel).
- `BEVGridTests` — cell binning by world `(X, Z)`, max-height tracking per
  cell, occupancy accumulation across multiple hits, out-of-extent points
  being ignored, and height measured relative to `groundY` (including
  clamping below-ground points to zero).

## Non-goals / explicitly out of scope for this package

- No ARKit session handling, depth capture, or confidence-map filtering.
- No SceneKit/Metal rendering of the resulting grid.
- No lens distortion modeling (pure pinhole unprojection).
- No dependency on `IPMCore` — the two stages are intentionally isolated.

These belong to later stages of the `swift-bev` experiment.
