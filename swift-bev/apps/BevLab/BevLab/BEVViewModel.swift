//
//  BEVViewModel.swift
//  BevLab
//
//  Created by K@zuki. on 2026/07/12.
//

import ARKit
import CoreImage
import IPMCore
import Observation
import os
import simd

/// Owns the `ARSession`, tracks the first detected horizontal plane, and
/// runs the per-frame IPM pipeline to produce a live bird's-eye-view image.
@MainActor
@Observable
final class BEVViewModel: NSObject {
  /// The shared AR session. `ARViewContainer` assigns this to its
  /// `ARSCNView.session` so the camera feed and plane rendering share the
  /// same tracking state instead of running two sessions.
  let session = ARSession()

  /// Latest rectified bird's-eye-view image, or `nil` when unavailable
  /// (no ground plane yet, or the ground rectangle isn't fully visible).
  private(set) var bevImage: CGImage?

  /// Human-readable status shown at the bottom of the screen.
  private(set) var statusText = "Point the camera at the floor…"

  /// Whether a horizontal ground plane has been found yet.
  private(set) var hasGroundPlane = false

  /// The ground rectangle currently being projected, in world space.
  /// Exposed so `ARViewContainer` can draw its outline.
  private(set) var currentGroundRect: GroundRect?

  /// Width/depth of the ground rectangle in meters. Bound to a UI slider.
  var rectSize: Double = 2.5

  /// Distance in meters from the camera to the rectangle's near-to-center point.
  private let standoff: Double = 2.0

  private let pipeline = IPMPipeline()
  private var groundY: Double?
  private var frameCounter = 0
  private var lastProcessedTime: TimeInterval = 0
  /// Minimum interval between processed frames, throttling to ~15 fps.
  private let minFrameInterval: TimeInterval = 1.0 / 15.0
  private let logger = Logger(subsystem: "dev.zuki.BevLab", category: "IPM")

  override init() {
    super.init()
    session.delegate = self
  }

  /// Starts (or restarts) the AR session with horizontal plane detection.
  func start() {
    let configuration = ARWorldTrackingConfiguration()
    configuration.planeDetection = [.horizontal]
    session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
  }

  /// Stops the AR session, e.g. when the view disappears.
  func stop() {
    session.pause()
  }
}

// MARK: - ARSessionDelegate

extension BEVViewModel: ARSessionDelegate {
  nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
    Task { @MainActor in
      self.process(frame: frame)
    }
  }

  nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
    let planeY =
      anchors
      .compactMap { $0 as? ARPlaneAnchor }
      .first { $0.alignment == .horizontal }
      .map { Double($0.transform.columns.3.y) }
    guard let planeY else { return }
    Task { @MainActor in
      // Keep the fallback `groundY` current as new horizontal planes are
      // discovered, rather than pinning it to whichever plane was found
      // first — the per-frame raycast in `process(frame:)` is the primary
      // source of truth, but this keeps the fallback path from drifting
      // too far from reality when the raycast misses for a while.
      let wasFirstPlane = self.groundY == nil
      self.groundY = planeY
      self.hasGroundPlane = true
      if wasFirstPlane {
        self.statusText = "Ground plane found. Rectifying…"
      }
    }
  }

  nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
    Task { @MainActor in
      self.statusText = "AR session failed: \(error.localizedDescription)"
    }
  }
}

// MARK: - Frame processing

extension BEVViewModel {
  private func process(frame: ARFrame) {
    // Throttle heavy per-frame work to keep the AR session smooth.
    let now = frame.timestamp
    guard now - lastProcessedTime >= minFrameInterval else { return }
    lastProcessedTime = now

    // Re-anchor to the real floor every frame instead of trusting a
    // once-set `groundY`: raycast from the camera along its forward look
    // direction and use the hit as the rectangle's center. This keeps the
    // ground rectangle glued to the floor as the user walks up/down slopes
    // or steps, instead of drifting off once the actual floor height
    // diverges from whatever plane was first detected.
    let cameraTransform = frame.camera.transform
    let origin = SIMD3<Float>(
      cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
    let forward = -simd_normalize(
      SIMD3<Float>(
        cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z))
    let query = ARRaycastQuery(
      origin: origin, direction: forward, allowing: .estimatedPlane, alignment: .horizontal)
    let hit = session.raycast(query).first

    let groundRect: GroundRect?
    if let hit {
      // Raycast found the floor this frame: re-anchor both the rectangle
      // and the fallback `groundY` to it so the fallback path (below)
      // never stays pinned to a stale height.
      let hitTransform = hit.worldTransform
      let hitPoint = SIMD3<Double>(
        Double(hitTransform.columns.3.x), Double(hitTransform.columns.3.y),
        Double(hitTransform.columns.3.z))
      groundY = hitPoint.y
      hasGroundPlane = true
      groundRect = GroundRectPlanner.makeGroundRect(
        center: hitPoint,
        cameraTransform: simd_double4x4(cameraTransform),
        width: rectSize,
        depth: rectSize)
    } else if let groundY {
      // No floor hit this frame (e.g. camera pointed at a wall or off the
      // edge of tracked geometry): fall back to the last known plane
      // height, projected `standoff` meters in front of the camera.
      groundRect = GroundRectPlanner.makeGroundRect(
        cameraTransform: simd_double4x4(cameraTransform),
        groundY: groundY,
        width: rectSize,
        depth: rectSize,
        standoff: standoff)
    } else {
      groundRect = nil
    }

    guard let groundRect else {
      bevImage = nil
      currentGroundRect = nil
      if !hasGroundPlane {
        statusText = "Point the camera at the floor…"
      }
      return
    }
    currentGroundRect = groundRect
    let corners = groundRect.worldCorners

    let rectified = pipeline.makeBEVImage(
      pixelBuffer: frame.capturedImage,
      intrinsics: frame.camera.intrinsics,
      cameraTransform: frame.camera.transform,
      groundCorners: corners)

    bevImage = rectified
    statusText =
      rectified == nil
      ? "Ground rectangle not fully in view…"
      : "BEV live (\(Int(rectSize * 100)) cm rect)"

    frameCounter += 1
    if frameCounter % 30 == 0 {
      let result = pipeline.crossCheck(frame: frame, groundCorners: corners)
      logger.debug(
        "cross-check max pixel diff: \(result.maxPixelDifference, format: .fixed(precision: 3))")
    }
  }
}
