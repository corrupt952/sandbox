# swift-bev

Turning an iPhone's first-person camera into a **bird's-eye-view (BEV)** —
a top-down, metrically-scaled view of the ground and (later) the 3D scene.
Target device: iPhone 15 Pro Max (has LiDAR).

Built in isolated stages, each its own subdirectory so they don't affect one
another. The pure-geometry stages are dependency-free Swift packages that build
and test headlessly (`swift test`, no Xcode/device); the ARKit app stages come
later.

## Two variants

- **Variant 1 — planar homography IPM** (no LiDAR). Assume the ground is a
  plane; project a metric ground rectangle's 4 corners into the live camera
  image (via `ARCamera.projectPoint`) and rectify with a 4-point perspective
  correction. Fast, flat-ground only. Continuation of `swift-perspective-cam`.
- **Variant 2 — LiDAR 3D BEV** (uses depth/mesh). Reconstruct 3D geometry from
  `ARFrame.sceneDepth` / scene-reconstruction mesh, accumulate into a world
  grid, and render a top-down occupancy/height map. Handles obstacles/height.

## Roadmap

| Stage | Dir | Status |
|-------|-----|--------|
| V1-0 pure IPM geometry (homography, pinhole projection, ground rect, metric scale) | [`ipm-core/`](ipm-core/) | ✅ done, 14 tests green |
| V1-1 ARKit app skeleton (session, camera feed, plane detection) | `apps/BevLab/` | ✅ done (device-runnable) |
| V1-2 wire IPM: project ground rect → CIPerspectiveCorrection → live BEV | `apps/BevLab/` | ✅ done (device-runnable) |
| V1-3 orientation polish + metric-scale validation + perf (off-main CI) | `apps/BevLab/` | next (after device feedback) |
| V1-4 walking stability / tuning | `apps/BevLab/` | later |
| V2-0 pure depth→world→grid binning geometry (`DepthUnprojector`, `BEVGrid`) | [`depth-core/`](depth-core/) | ✅ done, 13 tests green |
| V2-A SceneKit orthographic top-down of point cloud (quick visual) | `apps/BevLab/` | later |
| V2-B Metal occupancy/height-map BEV (metric) | `apps/BevLab/` | later |

Recommended order: finish Variant 1 first (reuses the perspective-correction
foundation, no LiDAR), then Variant 2.
