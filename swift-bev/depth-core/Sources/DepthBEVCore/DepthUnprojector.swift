import Foundation
import simd

/// Turns a LiDAR depth-map pixel into a world-space point, using the ARKit
/// convention.
///
/// This is the exact inverse of `IPMCore.PinholeCamera.project(_:)`. That
/// projector:
/// 1. Transforms a world point into ARKit camera space (+X right, +Y up,
///    -Z forward) via `simd_inverse(cameraTransform)`.
/// 2. Converts into the "vision" frame the intrinsics matrix expects
///    (+X right, +Y down, +Z forward) by negating Y and dividing by the
///    positive depth `-z`.
/// 3. Applies the intrinsics matrix to get pixel coordinates.
///
/// `DepthUnprojector` walks this backwards:
/// 1. Un-applies the intrinsics matrix to a pixel + depth to get a
///    vision-frame point: `xn = (u - cx) / fx`, `yn = (v - cy) / fy`,
///    vision point `= (xn * depth, yn * depth, depth)`.
/// 2. Converts back into ARKit camera space by negating Y and Z:
///    `(xn * depth, -yn * depth, -depth)`.
/// 3. Transforms into world space via `cameraTransform` (camera-to-world,
///    the ARKit `ARCamera.transform` convention).
///
/// Depth-map pixels use a top-left origin with `+v` pointing down, matching
/// the raw ARKit depth buffer layout (before any UI-space flipping).
public struct DepthUnprojector {
  /// Camera intrinsics matrix for the depth image's resolution (e.g. for a
  /// 256x192 LiDAR depth map, not the full-resolution color image), in the
  /// conventional form:
  /// ```
  /// | fx  0  cx |
  /// | 0  fy  cy |
  /// | 0   0   1 |
  /// ```
  public var intrinsics: simd_double3x3

  /// Camera-to-world transform (the camera's pose in world space), using
  /// the ARKit convention: camera looks down local -Z, +X right, +Y up.
  public var cameraTransform: simd_double4x4

  /// Depth-map size in pixels, as (width, height).
  public var imageSize: SIMD2<Double>

  public init(intrinsics: simd_double3x3, cameraTransform: simd_double4x4, imageSize: SIMD2<Double>)
  {
    self.intrinsics = intrinsics
    self.cameraTransform = cameraTransform
    self.imageSize = imageSize
  }

  /// Convenience initializer for a simple intrinsics matrix built from
  /// focal lengths and a principal point.
  public init(
    fx: Double, fy: Double, cx: Double, cy: Double, cameraTransform: simd_double4x4,
    imageSize: SIMD2<Double>
  ) {
    let intrinsics = simd_double3x3(
      rows: [
        SIMD3<Double>(fx, 0, cx),
        SIMD3<Double>(0, fy, cy),
        SIMD3<Double>(0, 0, 1),
      ])
    self.init(intrinsics: intrinsics, cameraTransform: cameraTransform, imageSize: imageSize)
  }

  /// Unprojects a depth-map pixel into ARKit camera space (+X right, +Y up,
  /// -Z forward), before applying `cameraTransform`.
  ///
  /// - Parameters:
  ///   - u: Pixel column, top-left origin.
  ///   - v: Pixel row, top-left origin, increasing downward.
  ///   - depth: Positive distance in meters in front of the camera.
  public func cameraPoint(u: Double, v: Double, depth: Double) -> SIMD3<Double> {
    let fx = intrinsics[0][0]
    let fy = intrinsics[1][1]
    let cx = intrinsics[2][0]
    let cy = intrinsics[2][1]

    let xn = (u - cx) / fx
    let yn = (v - cy) / fy

    // Vision-frame point (+Y down, +Z forward) is (xn * depth, yn * depth,
    // depth). Convert into ARKit camera space (+Y up, -Z forward) by
    // negating Y and Z.
    return SIMD3<Double>(xn * depth, -yn * depth, -depth)
  }

  /// Unprojects a depth-map pixel into world space.
  ///
  /// - Parameters:
  ///   - u: Pixel column, top-left origin.
  ///   - v: Pixel row, top-left origin, increasing downward.
  ///   - depth: Positive distance in meters in front of the camera.
  public func worldPoint(u: Double, v: Double, depth: Double) -> SIMD3<Double> {
    let camera = cameraPoint(u: u, v: v, depth: depth)
    let cameraHomogeneous = SIMD4<Double>(camera.x, camera.y, camera.z, 1)
    let world = cameraTransform * cameraHomogeneous
    return SIMD3<Double>(world.x, world.y, world.z)
  }
}
