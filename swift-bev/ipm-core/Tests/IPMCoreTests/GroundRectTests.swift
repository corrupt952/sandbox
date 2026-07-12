import Testing
import simd

@testable import IPMCore

@Suite
struct GroundRectTests {
  @Test
  func worldCorners_forwardFacingNegativeZ_ordersAndSizesCornersCorrectly() {
    let rect = GroundRect(
      width: 2, depth: 4,
      center: SIMD3<Double>(1, 0.5, -5),
      forward: SIMD2<Double>(0, -1))

    let corners = rect.worldCorners

    #expect(corners.count == 4)

    let topLeft = corners[0]
    let topRight = corners[1]
    let bottomRight = corners[2]
    let bottomLeft = corners[3]

    // All corners share the plane's Y.
    for c in corners {
      #expect(abs(c.y - 0.5) < 1e-12)
    }

    // Forward = (0, -1) in (x, z): "top" edge (topLeft/topRight) is at
    // more negative Z than "bottom" edge (bottomLeft/bottomRight).
    #expect(topLeft.z < bottomLeft.z)
    #expect(topRight.z < bottomRight.z)

    // Right direction = forward rotated -90°: for forward (0,-1) that's
    // (-1, 0), meaning "right" points towards -X... let's just assert
    // topLeft/topRight and bottomLeft/bottomRight are on opposite X
    // sides and symmetric about the center.
    #expect(topLeft.x != topRight.x)
    #expect(abs((topLeft.x + topRight.x) / 2 - 1) < 1e-12)
    #expect(abs((bottomLeft.x + bottomRight.x) / 2 - 1) < 1e-12)

    // Width/depth extents.
    #expect(abs(abs(topRight.x - topLeft.x) - 2) < 1e-12)
    #expect(abs(abs(topLeft.z - bottomLeft.z) - 4) < 1e-12)
  }

  @Test
  func worldCorners_defaultForward_facesNegativeZ() {
    let rect = GroundRect(width: 1, depth: 1, center: SIMD3<Double>(0, 0, 0))

    let corners = rect.worldCorners

    // Default forward (0, -1): topLeft/topRight should be at z = -0.5.
    #expect(abs(corners[0].z - (-0.5)) < 1e-12)
    #expect(abs(corners[1].z - (-0.5)) < 1e-12)
    #expect(abs(corners[2].z - 0.5) < 1e-12)
    #expect(abs(corners[3].z - 0.5) < 1e-12)
  }
}
