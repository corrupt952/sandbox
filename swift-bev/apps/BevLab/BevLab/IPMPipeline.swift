//
//  IPMPipeline.swift
//  BevLab
//
//  Created by K@zuki. on 2026/07/12.
//

import ARKit
import CoreImage
import CoreImage.CIFilterBuiltins
import IPMCore
import UIKit
import simd

/// Per-frame image work that turns an ARKit camera frame plus a ground
/// rectangle into a rectified bird's-eye-view `CGImage`.
///
/// Holds a reused `CIContext` since creating one per frame is expensive.
/// Every method here is otherwise stateless: given the same inputs it
/// produces the same output.
final class IPMPipeline {
  /// Fixed square output size (in pixels) for the rectified BEV image.
  static let outputSize = 512

  private let ciContext: CIContext

  init(ciContext: CIContext = CIContext(options: [.useSoftwareRenderer: false])) {
    self.ciContext = ciContext
  }

  /// Result of comparing our own `PinholeCamera.project` against ARKit's
  /// `ARCamera.projectPoint` for the same ground corners, used as an
  /// on-device cross-check that the pure projection math matches ARKit.
  struct CrossCheckResult {
    var maxPixelDifference: Double
  }

  /// Rectifies `pixelBuffer` into a top-down view of `groundCorners`.
  ///
  /// - Parameters:
  ///   - pixelBuffer: The ARFrame's `capturedImage` (sensor-native YCbCr,
  ///     landscape orientation).
  ///   - intrinsics: Camera intrinsics (`ARCamera.intrinsics`, Float).
  ///   - cameraTransform: Camera-to-world transform (`ARCamera.transform`, Float).
  ///   - groundCorners: The 4 world-space ground rectangle corners, in
  ///     `[topLeft, topRight, bottomRight, bottomLeft]` order.
  /// - Returns: A rectified `CGImage`, or `nil` if any corner is behind the
  ///   camera (BEV not available this frame).
  func makeBEVImage(
    pixelBuffer: CVPixelBuffer,
    intrinsics: simd_float3x3,
    cameraTransform: simd_float4x4,
    groundCorners: [SIMD3<Double>]
  ) -> CGImage? {
    let imageWidth = CVPixelBufferGetWidth(pixelBuffer)
    let imageHeight = CVPixelBufferGetHeight(pixelBuffer)
    let camera = PinholeCamera(
      intrinsics: simd_double3x3(intrinsics),
      cameraTransform: simd_double4x4(cameraTransform),
      imageSize: SIMD2<Double>(Double(imageWidth), Double(imageHeight)))

    guard let quad = IPM.imageQuad(groundCorners: groundCorners, camera: camera) else {
      // At least one corner is behind the camera; nothing to rectify.
      return nil
    }
    guard
      let corners = IPM.flippedPerspectiveCorners(quad: quad, imageHeight: Double(imageHeight))
    else {
      return nil
    }

    let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
    let filter = CIFilter.perspectiveCorrection()
    filter.inputImage = sourceImage
    // `GroundRect.worldCorners` orders corners "as seen from above" (looking
    // down -Y), so its "right" is the mirror image of the camera's physical
    // right (looking down -Y flips the sense of left/right versus looking
    // along the camera's forward axis). Left/right are swapped here so the
    // rectified BEV image matches the camera's actual left/right — i.e. the
    // world's left corner is fed into the BEV's left slot. Near/far
    // (top/bottom) are unaffected and stay as computed.
    filter.topLeft = CGPoint(x: corners.topRight.x, y: corners.topRight.y)
    filter.topRight = CGPoint(x: corners.topLeft.x, y: corners.topLeft.y)
    filter.bottomLeft = CGPoint(x: corners.bottomRight.x, y: corners.bottomRight.y)
    filter.bottomRight = CGPoint(x: corners.bottomLeft.x, y: corners.bottomLeft.y)

    guard let correctedImage = filter.outputImage else { return nil }
    let extent = correctedImage.extent
    guard extent.isEmpty == false, extent.width.isFinite, extent.height.isFinite else {
      return nil
    }

    guard let rectifiedCGImage = ciContext.createCGImage(correctedImage, from: extent) else {
      return nil
    }

    return Self.resize(rectifiedCGImage, to: Self.outputSize)
  }

  /// Cross-checks `PinholeCamera.project` against ARKit's own
  /// `ARCamera.projectPoint` for the same corners, returning the max
  /// per-axis pixel difference across all 4 corners that are visible to
  /// both projections.
  func crossCheck(
    frame: ARFrame,
    groundCorners: [SIMD3<Double>]
  ) -> CrossCheckResult {
    let imageWidth = CVPixelBufferGetWidth(frame.capturedImage)
    let imageHeight = CVPixelBufferGetHeight(frame.capturedImage)
    let viewportSize = CGSize(width: imageWidth, height: imageHeight)

    let camera = PinholeCamera(
      intrinsics: simd_double3x3(frame.camera.intrinsics),
      cameraTransform: simd_double4x4(frame.camera.transform),
      imageSize: SIMD2<Double>(Double(imageWidth), Double(imageHeight)))

    var maxDifference = 0.0
    for corner in groundCorners {
      guard let ours = camera.project(corner) else { continue }
      let cornerFloat = SIMD3<Float>(Float(corner.x), Float(corner.y), Float(corner.z))
      let arkitPoint = frame.camera.projectPoint(
        cornerFloat, orientation: .landscapeRight, viewportSize: viewportSize)
      let dx = abs(ours.x - Double(arkitPoint.x))
      let dy = abs(ours.y - Double(arkitPoint.y))
      maxDifference = max(maxDifference, max(dx, dy))
    }
    return CrossCheckResult(maxPixelDifference: maxDifference)
  }

  /// Resizes `image` to a `size` x `size` square using a fresh `CGContext`.
  private static func resize(_ image: CGImage, to size: Int) -> CGImage? {
    guard
      let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
      return nil
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return context.makeImage()
  }
}
