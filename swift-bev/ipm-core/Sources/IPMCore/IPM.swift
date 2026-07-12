import Foundation
import simd

/// Helper functions for setting up an inverse perspective mapping (IPM) /
/// bird's-eye-view transform: projecting a ground rectangle into the image,
/// and preparing the resulting quad for a 4-point perspective-correction
/// step (e.g. a Core Image `CIPerspectiveTransform`-style filter, applied
/// elsewhere — this package has no CoreImage dependency).
public enum IPM {

  /// Projects the 4 world-space corners of a ground rectangle into image
  /// pixel coordinates using the given camera.
  ///
  /// - Returns: The 4 image-space points in the same order as
  ///   `groundCorners` (typically `[topLeft, topRight, bottomRight, bottomLeft]`
  ///   per `GroundRect.worldCorners`), or `nil` if any corner is behind the
  ///   camera.
  public static func imageQuad(groundCorners: [SIMD3<Double>], camera: PinholeCamera) -> [SIMD2<
    Double
  >]? {
    var result: [SIMD2<Double>] = []
    result.reserveCapacity(groundCorners.count)
    for corner in groundCorners {
      guard let p = camera.project(corner) else { return nil }
      result.append(p)
    }
    return result
  }

  /// Flips a point's Y coordinate to convert between top-left-origin image
  /// coordinates (ARKit / UIKit convention, Y increases downward) and
  /// bottom-left-origin coordinates (Core Image convention, Y increases
  /// upward).
  ///
  /// This is its own inverse: applying it twice returns the original point.
  public static func flipY(_ p: SIMD2<Double>, imageHeight: Double) -> SIMD2<Double> {
    SIMD2<Double>(p.x, imageHeight - p.y)
  }

  /// The 4 named corner roles of a perspective-correction quad, matching
  /// the labels expected by Core Image's 4-point perspective filters
  /// (`inputTopLeft`, `inputTopRight`, `inputBottomRight`, `inputBottomLeft`).
  public struct PerspectiveCorners {
    public var topLeft: SIMD2<Double>
    public var topRight: SIMD2<Double>
    public var bottomRight: SIMD2<Double>
    public var bottomLeft: SIMD2<Double>

    public init(
      topLeft: SIMD2<Double>, topRight: SIMD2<Double>, bottomRight: SIMD2<Double>,
      bottomLeft: SIMD2<Double>
    ) {
      self.topLeft = topLeft
      self.topRight = topRight
      self.bottomRight = bottomRight
      self.bottomLeft = bottomLeft
    }
  }

  /// Converts an image-space quad (top-left origin, as produced by
  /// `imageQuad`, in `[topLeft, topRight, bottomRight, bottomLeft]` order)
  /// into Y-flipped, corner-labeled points ready to feed a Core-Image-style
  /// 4-point perspective-correction filter (bottom-left origin).
  ///
  /// - Parameters:
  ///   - quad: 4 points in `[topLeft, topRight, bottomRight, bottomLeft]` order,
  ///     in top-left-origin image coordinates.
  ///   - imageHeight: Height of the source image in pixels, used for the flip.
  public static func flippedPerspectiveCorners(quad: [SIMD2<Double>], imageHeight: Double)
    -> PerspectiveCorners?
  {
    guard quad.count == 4 else { return nil }
    let flipped = quad.map { flipY($0, imageHeight: imageHeight) }
    return PerspectiveCorners(
      topLeft: flipped[0],
      topRight: flipped[1],
      bottomRight: flipped[2],
      bottomLeft: flipped[3]
    )
  }

  /// Computes the metric scale (millimeters per output pixel) for a
  /// bird's-eye-view render, given the output resolution (in pixels, along
  /// one axis) and the real-world extent (in meters) that this axis of the
  /// rectified rectangle spans.
  ///
  /// - Parameters:
  ///   - outputPixels: Size of the output BEV image along one axis, in pixels.
  ///   - rectMeters: Real-world size of the ground rectangle along the same
  ///     axis, in meters.
  /// - Returns: Millimeters represented by one output pixel.
  public static func mmPerPixel(outputPixels: Double, rectMeters: Double) -> Double {
    (rectMeters * 1000) / outputPixels
  }
}
