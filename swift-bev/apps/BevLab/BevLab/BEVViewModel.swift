//
//  BEVViewModel.swift
//  BevLab
//
//  Created by K@zuki. on 2026/07/12.
//

import ARKit
import IPMCore
import Observation
import UIKit

/// Owns the `ARSession`, tracks the first detected horizontal plane, and
/// publishes the live bird's-eye-view image produced by `BEVFrameProcessor`.
///
/// The heavy per-frame IPM work (raycast aside) runs off the main actor in
/// `BEVFrameProcessor`; this type only holds UI-facing state and forwards
/// ARKit delegate callbacks to the processor.
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
  var rectSize: Double = 2.5 {
    didSet { frameProcessor.updateRectSize(rectSize) }
  }

  private let frameProcessor: BEVFrameProcessor

  init(frameProcessor: BEVFrameProcessor? = nil) {
    self.frameProcessor = frameProcessor ?? BEVFrameProcessor(initialRectSize: 2.5)
    super.init()
    self.frameProcessor.session = session
    self.frameProcessor.onResult = { [weak self] result in
      self?.apply(result)
    }
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

  /// PNG snapshot of the current BEV image at native resolution, or `nil`
  /// when no BEV image is available. Used by the share button so saved
  /// files preserve the exact output pixels for metric-scale measurement.
  func makeSnapshot() -> BEVSnapshot? {
    guard let bevImage else { return nil }
    guard let pngData = UIImage(cgImage: bevImage).pngData() else { return nil }
    let timestamp = Date().formatted(
      .verbatim(
        "\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
        timeZone: .current, calendar: .current))
    return BEVSnapshot(
      pngData: pngData,
      filename: "bev-\(Int(rectSize * 100))cm-\(timestamp).png")
  }

  // MARK: - Private

  /// Applies a `BEVFrameProcessor.Result` to the published UI state,
  /// mirroring the status-text rules the single-threaded pipeline used to
  /// apply inline.
  private func apply(_ result: BEVFrameProcessor.Result) {
    hasGroundPlane = result.hasGroundPlane
    currentGroundRect = result.groundRect
    bevImage = result.bevImage

    guard result.groundRect != nil else {
      if !hasGroundPlane {
        statusText = "Point the camera at the floor…"
      }
      return
    }
    statusText =
      result.bevImage == nil
      ? "Ground rectangle not fully in view…"
      : "BEV live (\(Int(result.rectSizeMeters * 100)) cm rect)"
  }
}

// MARK: - ARSessionDelegate

extension BEVViewModel: ARSessionDelegate {
  nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
    frameProcessor.submit(frame: frame)
  }

  nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
    let planeY =
      anchors
      .compactMap { $0 as? ARPlaneAnchor }
      .first { $0.alignment == .horizontal }
      .map { Double($0.transform.columns.3.y) }
    guard let planeY else { return }
    frameProcessor.updateGroundY(planeY)
    Task { @MainActor in
      // Keep `hasGroundPlane`/`statusText` current as new horizontal planes
      // are discovered, rather than pinning them to whichever plane was
      // found first — the per-frame raycast in `BEVFrameProcessor` is the
      // primary source of truth, but this keeps the UI from lagging behind
      // when the raycast misses for a while.
      let wasFirstPlane = self.hasGroundPlane == false
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
