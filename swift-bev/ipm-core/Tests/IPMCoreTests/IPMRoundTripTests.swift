import Testing
import simd

@testable import IPMCore

@Suite
struct IPMRoundTripTests {
  /// Builds a camera-to-world transform (ARKit convention: camera looks
  /// down local -Z, +X right, +Y up) for a camera positioned at `position`
  /// and looking towards `target`, with `worldUp` used to resolve the
  /// remaining rotational degree of freedom (typically world +Y).
  private func lookAtTransform(
    position: SIMD3<Double>, target: SIMD3<Double>, worldUp: SIMD3<Double> = SIMD3<Double>(0, 1, 0)
  ) -> simd_double4x4 {
    let forward = simd_normalize(target - position)
    let right = simd_normalize(simd_cross(forward, worldUp))
    let up = simd_cross(right, forward)

    // Camera-to-world rotation: columns are the camera's local axes
    // expressed in world space. Local -Z is forward, so the local +Z
    // column is -forward.
    let col0 = SIMD4<Double>(right.x, right.y, right.z, 0)
    let col1 = SIMD4<Double>(up.x, up.y, up.z, 0)
    let col2 = SIMD4<Double>(-forward.x, -forward.y, -forward.z, 0)
    let col3 = SIMD4<Double>(position.x, position.y, position.z, 1)

    return simd_double4x4(columns: (col0, col1, col2, col3))
  }

  @Test
  func imageQuadAndHomography_tiltedCamera_recoversInteriorGroundPoint() throws {
    // Camera mounted 2m above ground, 4m back, tilted down to look at a
    // point on the ground 3m in front of its base position.
    let cameraPosition = SIMD3<Double>(0, 2, 4)
    let lookTarget = SIMD3<Double>(0, 0, -1)
    let transform = lookAtTransform(position: cameraPosition, target: lookTarget)

    let imageSize = SIMD2<Double>(1920, 1080)
    let camera = PinholeCamera(
      fx: 1000, fy: 1000, cx: imageSize.x / 2, cy: imageSize.y / 2,
      cameraTransform: transform, imageSize: imageSize)

    // A 3m x 3m ground rectangle centered 1m in front of the look target,
    // squarely within the camera's view.
    let rectWidth = 3.0
    let rectDepth = 3.0
    let rect = GroundRect(
      width: rectWidth, depth: rectDepth,
      center: SIMD3<Double>(0, 0, -1),
      forward: SIMD2<Double>(0, -1))

    let groundCorners = rect.worldCorners
    let imageQuad = try #require(IPM.imageQuad(groundCorners: groundCorners, camera: camera))
    #expect(imageQuad.count == 4)

    // All 4 corners must land within the image bounds for this to be a
    // sane BEV setup.
    for p in imageQuad {
      #expect(p.x >= 0)
      #expect(p.x <= imageSize.x)
      #expect(p.y >= 0)
      #expect(p.y <= imageSize.y)
    }

    // Ground-plane (X, Z) coordinates of the 4 corners, in the same
    // order as groundCorners / imageQuad.
    let groundXZ = groundCorners.map { SIMD2<Double>($0.x, $0.z) }

    // Homography mapping image -> ground(X, Z).
    let Himg2ground = try #require(Homography.homography(from: imageQuad, to: groundXZ))

    // Pick an interior ground point (not one of the 4 corners) within
    // the rectangle, project it through the camera, then map the image
    // point back to ground via the homography, and check we recover the
    // original (X, Z).
    let interiorGround = SIMD3<Double>(0.3, 0, -0.4)
    let interiorImage = try #require(camera.project(interiorGround))
    let recoveredXZ = Homography.apply(Himg2ground, to: interiorImage)

    #expect(abs(recoveredXZ.x - interiorGround.x) < 1e-6)
    #expect(abs(recoveredXZ.y - interiorGround.z) < 1e-6)

    // Also verify the corners themselves round-trip through the same
    // homography.
    for i in 0..<4 {
      let mapped = Homography.apply(Himg2ground, to: imageQuad[i])
      #expect(abs(mapped.x - groundXZ[i].x) < 1e-6)
      #expect(abs(mapped.y - groundXZ[i].y) < 1e-6)
    }

    // Metric scale check: an output BEV image of 300x300 px representing
    // this 3m x 3m rectangle should have 10 mm per pixel.
    let mmPerPixelWidth = IPM.mmPerPixel(outputPixels: 300, rectMeters: rectWidth)
    let mmPerPixelDepth = IPM.mmPerPixel(outputPixels: 300, rectMeters: rectDepth)
    #expect(abs(mmPerPixelWidth - 10.0) < 1e-9)
    #expect(abs(mmPerPixelDepth - 10.0) < 1e-9)
  }

  @Test
  func flipY_appliedTwice_isSelfInverse() {
    let imageHeight = 1080.0
    let p = SIMD2<Double>(123.5, 400.25)

    let flipped = IPM.flipY(p, imageHeight: imageHeight)

    #expect(abs(flipped.x - p.x) < 1e-12)
    #expect(abs(flipped.y - (imageHeight - p.y)) < 1e-12)

    let flippedTwice = IPM.flipY(flipped, imageHeight: imageHeight)
    #expect(abs(flippedTwice.x - p.x) < 1e-12)
    #expect(abs(flippedTwice.y - p.y) < 1e-12)
  }

  @Test
  func flippedPerspectiveCorners_topLeftOriginQuad_labelsAndFlipsCorners() throws {
    let imageHeight = 1000.0
    // [topLeft, topRight, bottomRight, bottomLeft] in top-left-origin space.
    let quad: [SIMD2<Double>] = [
      SIMD2(10, 20), SIMD2(90, 25), SIMD2(85, 90), SIMD2(15, 95),
    ]

    let corners = try #require(IPM.flippedPerspectiveCorners(quad: quad, imageHeight: imageHeight))

    #expect(corners.topLeft == SIMD2(10, imageHeight - 20))
    #expect(corners.topRight == SIMD2(90, imageHeight - 25))
    #expect(corners.bottomRight == SIMD2(85, imageHeight - 90))
    #expect(corners.bottomLeft == SIMD2(15, imageHeight - 95))
  }
}
