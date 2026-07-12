import Foundation
import simd

/// A metric rectangle lying on a horizontal ground plane `y = planeY` in
/// world space (ARKit convention: +Y is up). The rectangle is centered at a
/// given world point and oriented by a facing direction in the X/Z plane.
public struct GroundRect: Sendable {
  /// Width of the rectangle in meters, measured along the local "right" axis.
  public var width: Double

  /// Depth of the rectangle in meters, measured along the local "forward" axis.
  public var depth: Double

  /// World-space center of the rectangle. Only `x` and `z` are used for
  /// positioning within the plane; `y` defines the plane height.
  public var center: SIMD3<Double>

  /// Forward direction of the rectangle in the X/Z plane (does not need to
  /// be normalized; only its direction is used). This points from the
  /// center towards the "top" edge (topLeft/topRight).
  public var forward: SIMD2<Double>

  public init(
    width: Double, depth: Double, center: SIMD3<Double>,
    forward: SIMD2<Double> = SIMD2<Double>(0, -1)
  ) {
    self.width = width
    self.depth = depth
    self.center = center
    self.forward = forward
  }

  /// The ground plane height (world-space Y).
  public var planeY: Double { center.y }

  /// The 4 world-space corners of the rectangle, as seen from above
  /// (looking down -Y), in a fixed order:
  /// `[topLeft, topRight, bottomRight, bottomLeft]`, where "top" is in the
  /// `forward` direction from the center and "left"/"right" are relative
  /// to that forward direction (right = forward rotated -90° in X/Z, i.e.
  /// consistent with a right-handed +Y-up world).
  public var worldCorners: [SIMD3<Double>] {
    let fwdLen = simd_length(forward)
    let fwdDir: SIMD2<Double> = fwdLen > 1e-12 ? forward / fwdLen : SIMD2<Double>(0, -1)

    // Right = forward rotated by -90 degrees in the X/Z plane:
    // (fx, fz) -> (fz, -fx). This keeps a right-handed sense when
    // looking down from +Y.
    let rightDir = SIMD2<Double>(fwdDir.y, -fwdDir.x)

    let halfWidth = width / 2
    let halfDepth = depth / 2

    let centerXZ = SIMD2<Double>(center.x, center.z)

    func point(rightScale: Double, forwardScale: Double) -> SIMD3<Double> {
      let xz = centerXZ + rightDir * (rightScale * halfWidth) + fwdDir * (forwardScale * halfDepth)
      return SIMD3<Double>(xz.x, center.y, xz.y)
    }

    let topLeft = point(rightScale: -1, forwardScale: 1)
    let topRight = point(rightScale: 1, forwardScale: 1)
    let bottomRight = point(rightScale: 1, forwardScale: -1)
    let bottomLeft = point(rightScale: -1, forwardScale: -1)

    return [topLeft, topRight, bottomRight, bottomLeft]
  }
}
