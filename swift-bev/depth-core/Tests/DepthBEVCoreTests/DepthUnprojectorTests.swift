import Testing
import simd

@testable import DepthBEVCore

@Suite
struct DepthUnprojectorTests {
  let fx: Double = 250
  let fy: Double = 250
  let imageSize = SIMD2<Double>(256, 192)
  let tolerance: Double = 1e-9

  func makeUnprojector(transform: simd_double4x4 = matrix_identity_double4x4) -> DepthUnprojector {
    DepthUnprojector(
      fx: fx, fy: fy, cx: imageSize.x / 2, cy: imageSize.y / 2,
      cameraTransform: transform, imageSize: imageSize)
  }

  @Test
  func cameraPoint_principalPointPixel_returnsPointOnOpticalAxis() {
    let unprojector = makeUnprojector()
    let depth = 2.0

    let point = unprojector.cameraPoint(u: imageSize.x / 2, v: imageSize.y / 2, depth: depth)

    #expect(abs(point.x - 0) < tolerance)
    #expect(abs(point.y - 0) < tolerance)
    #expect(abs(point.z - (-depth)) < tolerance)
  }

  @Test
  func cameraPoint_offPrincipalPixel_matchesInverseIntrinsicsFormula() {
    let unprojector = makeUnprojector()
    let depth = 2.0
    let u = imageSize.x / 2 + 50
    let v = imageSize.y / 2 - 30

    let point = unprojector.cameraPoint(u: u, v: v, depth: depth)

    let xn = (u - imageSize.x / 2) / fx
    let yn = (v - imageSize.y / 2) / fy
    let expected = SIMD3<Double>(xn * depth, -yn * depth, -depth)
    #expect(abs(point.x - expected.x) < tolerance)
    #expect(abs(point.y - expected.y) < tolerance)
    #expect(abs(point.z - expected.z) < tolerance)
  }

  @Test
  func worldPoint_identityTransform_equalsCameraPoint() {
    let unprojector = makeUnprojector(transform: matrix_identity_double4x4)
    let u = imageSize.x / 2 + 20
    let v = imageSize.y / 2 + 10
    let depth = 3.0

    let camera = unprojector.cameraPoint(u: u, v: v, depth: depth)
    let world = unprojector.worldPoint(u: u, v: v, depth: depth)

    #expect(abs(world.x - camera.x) < tolerance)
    #expect(abs(world.y - camera.y) < tolerance)
    #expect(abs(world.z - camera.z) < tolerance)
  }

  @Test
  func worldPoint_nonIdentityTransform_transformsCameraPointIntoWorldSpace() {
    let translation = SIMD3<Double>(1, 2, 3)
    var transform = matrix_identity_double4x4
    transform.columns.3 = SIMD4<Double>(translation.x, translation.y, translation.z, 1)
    let unprojector = makeUnprojector(transform: transform)
    let u = imageSize.x / 2
    let v = imageSize.y / 2
    let depth = 2.0

    let camera = unprojector.cameraPoint(u: u, v: v, depth: depth)
    let world = unprojector.worldPoint(u: u, v: v, depth: depth)

    let expected = camera + translation
    #expect(abs(world.x - expected.x) < tolerance)
    #expect(abs(world.y - expected.y) < tolerance)
    #expect(abs(world.z - expected.z) < tolerance)
  }

  @Test(
    arguments: [
      (SIMD2<Double>(128, 96), 1.5),
      (SIMD2<Double>(200, 40), 2.5),
      (SIMD2<Double>(10, 170), 4.0),
    ]
  )
  func worldPoint_roundTripThroughLocalPinholeProjection_recoversOriginalPixel(
    pixel: SIMD2<Double>, depth: Double
  ) throws {
    let cameraPosition = SIMD3<Double>(0, 1.5, 4)
    let transform = lookAtTransform(
      position: cameraPosition, target: SIMD3<Double>(0, 0, -1))
    let unprojector = DepthUnprojector(
      fx: fx, fy: fy, cx: imageSize.x / 2, cy: imageSize.y / 2,
      cameraTransform: transform, imageSize: imageSize)

    let world = unprojector.worldPoint(u: pixel.x, v: pixel.y, depth: depth)
    let reprojected = project(
      world, cameraTransform: transform, fx: fx, fy: fy, imageSize: imageSize)

    let projectedPixel = try #require(reprojected)
    #expect(abs(projectedPixel.x - pixel.x) < 1e-6)
    #expect(abs(projectedPixel.y - pixel.y) < 1e-6)
  }

  // MARK: - Local forward-projection helpers (mirrors IPMCore.PinholeCamera,
  // re-derived here so this test does not depend on IPMCore).

  private func lookAtTransform(
    position: SIMD3<Double>, target: SIMD3<Double>, worldUp: SIMD3<Double> = SIMD3<Double>(0, 1, 0)
  ) -> simd_double4x4 {
    let forward = simd_normalize(target - position)
    let right = simd_normalize(simd_cross(forward, worldUp))
    let up = simd_cross(right, forward)

    let col0 = SIMD4<Double>(right.x, right.y, right.z, 0)
    let col1 = SIMD4<Double>(up.x, up.y, up.z, 0)
    let col2 = SIMD4<Double>(-forward.x, -forward.y, -forward.z, 0)
    let col3 = SIMD4<Double>(position.x, position.y, position.z, 1)

    return simd_double4x4(columns: (col0, col1, col2, col3))
  }

  private func project(
    _ worldPoint: SIMD3<Double>, cameraTransform: simd_double4x4, fx: Double, fy: Double,
    imageSize: SIMD2<Double>
  ) -> SIMD2<Double>? {
    let worldToCamera = simd_inverse(cameraTransform)
    let worldHomogeneous = SIMD4<Double>(worldPoint.x, worldPoint.y, worldPoint.z, 1)
    let cameraSpace = worldToCamera * worldHomogeneous

    guard cameraSpace.z < 0 else {
      return nil
    }

    let depth = -cameraSpace.z
    let xn = cameraSpace.x / depth
    let yn = -cameraSpace.y / depth
    let u = fx * xn + imageSize.x / 2
    let v = fy * yn + imageSize.y / 2
    return SIMD2<Double>(u, v)
  }
}
