//
//  GroundRectPlanner.swift
//  BevLab
//
//  Created by K@zuki. on 2026/07/12.
//

import Foundation
import IPMCore
import simd

/// Pure helper that computes a metric ground rectangle in front of the
/// camera, projected onto a known ground plane height. Kept free of ARKit
/// types so the math can be unit-tested without a live AR session.
enum GroundRectPlanner {
  /// Computes a `GroundRect` centered `standoff` meters in front of the
  /// camera, flattened onto the horizontal plane at `groundY`.
  ///
  /// - Parameters:
  ///   - cameraTransform: Camera-to-world transform (ARKit convention: the
  ///     camera looks down its local -Z axis).
  ///   - groundY: World-space Y height of the ground plane.
  ///   - width: Rectangle width in meters.
  ///   - depth: Rectangle depth in meters.
  ///   - standoff: Distance in meters from the camera (projected onto the
  ///     ground plane) to the rectangle's center, along the camera's
  ///     flattened forward direction.
  /// - Returns: A `GroundRect` lying on `y = groundY`, or `nil` if the
  ///   camera's forward direction is (nearly) vertical, in which case no
  ///   stable horizontal facing can be derived.
  static func makeGroundRect(
    cameraTransform: simd_double4x4,
    groundY: Double,
    width: Double,
    depth: Double,
    standoff: Double
  ) -> GroundRect? {
    // Camera forward is local -Z transformed into world space.
    let forward3D = SIMD3<Double>(
      -cameraTransform.columns.2.x, -cameraTransform.columns.2.y, -cameraTransform.columns.2.z)
    let forwardXZ = SIMD2<Double>(forward3D.x, forward3D.z)
    let forwardLength = simd_length(forwardXZ)
    guard forwardLength > 1e-6 else { return nil }
    let forwardDir = forwardXZ / forwardLength

    let cameraPosition = SIMD3<Double>(
      cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
    let cameraXZ = SIMD2<Double>(cameraPosition.x, cameraPosition.z)
    let centerXZ = cameraXZ + forwardDir * standoff

    let center = SIMD3<Double>(centerXZ.x, groundY, centerXZ.y)
    return GroundRect(
      width: width, depth: depth, center: center,
      forward: forwardDir)
  }

  /// Computes a `GroundRect` centered exactly at `center` (typically a
  /// raycast hit on the real floor), facing the camera's flattened forward
  /// direction. Unlike `makeGroundRect(cameraTransform:groundY:...)`, this
  /// does not assume a fixed ground height or a fixed standoff distance —
  /// it re-anchors the rectangle to wherever `center` actually is, which
  /// keeps the rectangle glued to the floor across slopes and steps.
  ///
  /// - Parameters:
  ///   - center: World-space point on the real floor (e.g. an
  ///     `ARRaycastResult`'s hit position) to center the rectangle on.
  ///   - cameraTransform: Camera-to-world transform, used only to derive the
  ///     facing direction (ARKit convention: the camera looks down its
  ///     local -Z axis).
  ///   - width: Rectangle width in meters.
  ///   - depth: Rectangle depth in meters.
  /// - Returns: A `GroundRect` lying on `y = center.y`, or `nil` if the
  ///   camera's forward direction is (nearly) vertical, in which case no
  ///   stable horizontal facing can be derived.
  static func makeGroundRect(
    center: SIMD3<Double>,
    cameraTransform: simd_double4x4,
    width: Double,
    depth: Double
  ) -> GroundRect? {
    // Camera forward is local -Z transformed into world space.
    let forward3D = SIMD3<Double>(
      -cameraTransform.columns.2.x, -cameraTransform.columns.2.y, -cameraTransform.columns.2.z)
    let forwardXZ = SIMD2<Double>(forward3D.x, forward3D.z)
    let forwardLength = simd_length(forwardXZ)
    guard forwardLength > 1e-6 else { return nil }
    let forwardDir = forwardXZ / forwardLength

    return GroundRect(
      width: width, depth: depth, center: center,
      forward: forwardDir)
  }
}
