//
//  BEVFrameProcessor.swift
//  BevLab
//
//  Created by K@zuki. on 2026/07/12.
//

import ARKit
import IPMCore
import os
import simd

/// Runs the per-frame IPM pipeline off the main thread.
///
/// `ARSessionDelegate` callbacks arrive on ARKit's own delegate thread, and
/// `submit(frame:)` is expected to be called synchronously from there. It
/// performs the lightweight, latency-sensitive work (throttling, the ground
/// raycast, and `GroundRect` planning) inline on that thread, then extracts
/// only the plain values the heavy image pipeline needs — never the `ARFrame`
/// itself — before dispatching to a private serial queue. Keeping `ARFrame`
/// out of any retained closure avoids holding frames back in ARKit's frame
/// pool while the (comparatively slow) image work is still running.
/// `nonisolated` opts this class out of the project's MainActor default
/// isolation (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`) — its whole
/// purpose is to run off the main actor.
nonisolated final class BEVFrameProcessor: @unchecked Sendable {
  /// The AR session used for the per-frame ground raycast. Weak because the
  /// processor is a dependency of the session's owner, not the other way
  /// around.
  weak var session: ARSession?

  /// Called with the outcome of each processed frame, always on the main
  /// actor. `BEVViewModel` uses this to update its published UI state.
  var onResult: (@MainActor @Sendable (Result) -> Void)?

  /// Outcome of processing a single `ARFrame`, carrying everything
  /// `BEVViewModel` needs to update its UI state without touching ARKit
  /// types itself.
  struct Result: Sendable {
    var bevImage: CGImage?
    var groundRect: GroundRect?
    var hasGroundPlane: Bool
    var rectSizeMeters: Double
  }

  private struct State {
    var isProcessing = false
    var lastProcessedTime: TimeInterval = 0
    var groundY: Double?
    var hasGroundPlane = false
    var rectSize: Double
    var frameCounter = 0
  }

  /// Distance in meters from the camera to the rectangle's near-to-center
  /// point, used only for the fallback (no-raycast-hit) path.
  private let standoff: Double = 2.0

  /// Minimum interval between processed frames, throttling to ~15 fps.
  private let minFrameInterval: TimeInterval = 1.0 / 15.0

  private let pipeline: IPMPipeline
  private let processingQueue = DispatchQueue(
    label: "dev.zuki.BevLab.frame-processing", qos: .userInitiated)
  private let logger = Logger(subsystem: "dev.zuki.BevLab", category: "IPM")
  private let lock: OSAllocatedUnfairLock<State>

  init(pipeline: IPMPipeline = IPMPipeline(), initialRectSize: Double) {
    self.pipeline = pipeline
    self.lock = OSAllocatedUnfairLock(initialState: State(rectSize: initialRectSize))
  }

  // MARK: - Public API

  /// Updates the ground rectangle's width/depth, e.g. from a UI slider.
  func updateRectSize(_ rectSize: Double) {
    lock.withLock { $0.rectSize = rectSize }
  }

  /// Updates the fallback ground height from a newly discovered horizontal
  /// plane anchor. The per-frame raycast in `submit(frame:)` is the primary
  /// source of truth; this only keeps the fallback path from drifting too
  /// far from reality when the raycast misses for a while.
  func updateGroundY(_ groundY: Double) {
    lock.withLock {
      $0.groundY = groundY
      $0.hasGroundPlane = true
    }
  }

  /// Processes one `ARFrame`. Expected to be called synchronously from
  /// `ARSessionDelegate.session(_:didUpdate:)`, on ARKit's delegate thread.
  ///
  /// Throttling and busy-checking happen inline here, before anything is
  /// dispatched, so dropped frames never touch the processing queue and
  /// never get captured into a closure.
  func submit(frame: ARFrame) {
    let now = frame.timestamp
    let cameraTransform = frame.camera.transform

    let shouldProcess = lock.withLock { state -> Bool in
      guard now - state.lastProcessedTime >= minFrameInterval, state.isProcessing == false else {
        return false
      }
      state.lastProcessedTime = now
      state.isProcessing = true
      return true
    }
    guard shouldProcess else { return }

    // Re-anchor to the real floor every frame instead of trusting a
    // once-set ground height: raycast from the camera along its forward
    // look direction and use the hit as the rectangle's center. This keeps
    // the ground rectangle glued to the floor as the user walks up/down
    // slopes or steps, instead of drifting off once the actual floor height
    // diverges from whatever plane was first detected.
    let origin = SIMD3<Float>(
      cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
    let forward = -simd_normalize(
      SIMD3<Float>(
        cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z))
    let query = ARRaycastQuery(
      origin: origin, direction: forward, allowing: .estimatedPlane, alignment: .horizontal)
    let hit = session?.raycast(query).first

    let (groundRect, hasGroundPlane, rectSize) = lock.withLock {
      state -> (GroundRect?, Bool, Double) in
      if let hit {
        // Raycast found the floor this frame: re-anchor both the rectangle
        // and the fallback ground height to it so the fallback path never
        // stays pinned to a stale height.
        let hitTransform = hit.worldTransform
        let hitPoint = SIMD3<Double>(
          Double(hitTransform.columns.3.x), Double(hitTransform.columns.3.y),
          Double(hitTransform.columns.3.z))
        state.groundY = hitPoint.y
        state.hasGroundPlane = true
        let rect = GroundRectPlanner.makeGroundRect(
          center: hitPoint,
          cameraTransform: simd_double4x4(cameraTransform),
          width: state.rectSize,
          depth: state.rectSize)
        return (rect, state.hasGroundPlane, state.rectSize)
      } else if let groundY = state.groundY {
        // No floor hit this frame (e.g. camera pointed at a wall or off the
        // edge of tracked geometry): fall back to the last known plane
        // height, projected `standoff` meters in front of the camera.
        let rect = GroundRectPlanner.makeGroundRect(
          cameraTransform: simd_double4x4(cameraTransform),
          groundY: groundY,
          width: state.rectSize,
          depth: state.rectSize,
          standoff: standoff)
        return (rect, state.hasGroundPlane, state.rectSize)
      } else {
        return (nil, state.hasGroundPlane, state.rectSize)
      }
    }

    guard let groundRect else {
      lock.withLock { $0.isProcessing = false }
      deliver(
        Result(
          bevImage: nil, groundRect: nil, hasGroundPlane: hasGroundPlane, rectSizeMeters: rectSize))
      return
    }

    // Extract only the plain values the image pipeline needs. The `ARFrame`
    // itself is never captured past this point, so it can return to ARKit's
    // frame pool as soon as this delegate call returns.
    // `nonisolated(unsafe)`: the buffer's ownership transfers wholesale to
    // the serial processing queue; nothing else touches it afterwards.
    nonisolated(unsafe) let pixelBuffer = frame.capturedImage
    let camera = frame.camera
    let corners = groundRect.worldCorners

    processingQueue.async { [self] in
      let bevImage = pipeline.makeBEVImage(
        pixelBuffer: pixelBuffer,
        intrinsics: camera.intrinsics,
        cameraTransform: camera.transform,
        groundCorners: corners)

      let shouldCrossCheck = lock.withLock { state -> Bool in
        state.frameCounter += 1
        return state.frameCounter % 30 == 0
      }
      if shouldCrossCheck {
        let imageWidth = CVPixelBufferGetWidth(pixelBuffer)
        let imageHeight = CVPixelBufferGetHeight(pixelBuffer)
        let result = pipeline.crossCheck(
          camera: camera, imageWidth: imageWidth, imageHeight: imageHeight, groundCorners: corners)
        logger.debug(
          "cross-check max pixel diff: \(result.maxPixelDifference, format: .fixed(precision: 3))")
      }

      lock.withLock { $0.isProcessing = false }
      deliver(
        Result(
          bevImage: bevImage, groundRect: groundRect, hasGroundPlane: hasGroundPlane,
          rectSizeMeters: rectSize))
    }
  }

  // MARK: - Private

  private func deliver(_ result: Result) {
    guard let onResult else { return }
    Task { @MainActor in
      onResult(result)
    }
  }
}
