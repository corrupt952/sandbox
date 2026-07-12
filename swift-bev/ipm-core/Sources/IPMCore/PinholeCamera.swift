import Foundation
import simd

/// A simple pinhole camera model using the ARKit convention:
///
/// - The camera's local space is right-handed with the camera looking down
///   its local **-Z** axis, **+X** to the right, and **+Y** up. This matches
///   the convention used by `ARCamera.transform` (world-from-camera).
/// - `cameraTransform` is the camera-to-world transform (i.e. the camera's
///   pose expressed in world space), exactly like `ARCamera.transform`.
/// - World space follows ARKit's convention as well: right-handed, +Y up.
///
/// To project a world point into image space we:
/// 1. Transform the point into camera space via `simd_inverse(cameraTransform)`.
/// 2. Discard points with camera-space `z >= 0` (behind the camera, since
///    forward is -Z).
/// 3. Perspective-divide by `-z` (the positive "depth" in front of the
///    camera) and apply the intrinsics matrix to get pixel coordinates.
public struct PinholeCamera {
  /// Camera intrinsics matrix, in the conventional form:
  /// ```
  /// | fx  0  cx |
  /// | 0  fy  cy |
  /// | 0   0   1 |
  /// ```
  /// Stored as a `simd_double3x3` (column-major).
  public var intrinsics: simd_double3x3

  /// Camera-to-world transform (the camera's pose in world space), using
  /// the ARKit convention: camera looks down local -Z, +X right, +Y up.
  public var cameraTransform: simd_double4x4

  /// Image size in pixels, as (width, height).
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

  /// Projects a world-space point into image pixel coordinates.
  ///
  /// Returns `nil` if the point is behind the camera (camera-space `z >= 0`,
  /// since the camera looks down local -Z).
  public func project(_ worldPoint: SIMD3<Double>) -> SIMD2<Double>? {
    let worldToCamera = simd_inverse(cameraTransform)
    let worldHomogeneous = SIMD4<Double>(worldPoint.x, worldPoint.y, worldPoint.z, 1)
    let cameraSpace = worldToCamera * worldHomogeneous

    guard cameraSpace.z < 0 else {
      // On or behind the camera plane (forward is -Z), not visible.
      return nil
    }

    // Convert from the ARKit camera frame (+Y up, -Z forward) into the frame
    // the intrinsics matrix expects (+Y down, +Z forward) before dividing by
    // depth. Negating Y is what makes a point above the optical axis land
    // above the principal point (v < cy), matching ARKit's intrinsics /
    // ARCamera.projectPoint convention.
    let depth = -cameraSpace.z
    let normalized = SIMD3<Double>(cameraSpace.x / depth, -cameraSpace.y / depth, 1)
    let pixel = intrinsics * normalized
    return SIMD2<Double>(pixel.x, pixel.y)
  }
}
