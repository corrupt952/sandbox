import Testing
import simd

@testable import IPMCore

@Suite
struct PinholeCameraTests {
  let fx: Double = 1000
  let fy: Double = 1000
  let imageSize = SIMD2<Double>(1920, 1080)

  func makeCamera(transform: simd_double4x4 = matrix_identity_double4x4) -> PinholeCamera {
    PinholeCamera(
      fx: fx, fy: fy, cx: imageSize.x / 2, cy: imageSize.y / 2,
      cameraTransform: transform, imageSize: imageSize)
  }

  @Test
  func project_principalPointPoint_projectsToPrincipalPixel() throws {
    let camera = makeCamera()
    let point = SIMD3<Double>(0, 0, -2)

    let projected = try #require(camera.project(point))

    #expect(abs(projected.x - imageSize.x / 2) < 1e-9)
    #expect(abs(projected.y - imageSize.y / 2) < 1e-9)
  }

  @Test
  func project_offAxisPoint_matchesPinholeFormula() throws {
    let camera = makeCamera()
    let X = 0.5
    let point = SIMD3<Double>(X, 0, -2)

    let projected = try #require(camera.project(point))

    let expectedX = imageSize.x / 2 + fx * (X / 2)
    #expect(abs(projected.x - expectedX) < 1e-9)
    #expect(abs(projected.y - imageSize.y / 2) < 1e-9)
  }

  @Test
  func project_verticalOffAxisPoint_projectsAbovePrincipalPixel() throws {
    // A point above the optical axis (camera +Y is up) must project ABOVE the
    // principal point — i.e. a smaller v, since image rows increase downward.
    // This pins the ARKit / ARCamera.projectPoint intrinsics convention.
    let camera = makeCamera()
    let Y = 0.25
    let point = SIMD3<Double>(0, Y, -2)

    let projected = try #require(camera.project(point))

    let expectedY = imageSize.y / 2 - fy * (Y / 2)
    #expect(projected.y < imageSize.y / 2)
    #expect(abs(projected.x - imageSize.x / 2) < 1e-9)
    #expect(abs(projected.y - expectedY) < 1e-9)
  }

  @Test
  func project_pointBehindCamera_returnsNil() {
    let camera = makeCamera()
    let point = SIMD3<Double>(0, 0, 2)

    #expect(camera.project(point) == nil)
  }

  @Test
  func project_pointOnCameraPlane_returnsNil() {
    let camera = makeCamera()
    let point = SIMD3<Double>(0, 0, 0)

    #expect(camera.project(point) == nil)
  }
}
