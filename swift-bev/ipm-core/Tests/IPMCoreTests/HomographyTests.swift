import Testing
import simd

@testable import IPMCore

@Suite
struct HomographyTests {
  @Test
  func homography_identityCorrespondences_mapsPointsUnchanged() throws {
    let src: [SIMD2<Double>] = [
      SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1),
    ]
    let dst = src

    let H = try #require(Homography.homography(from: src, to: dst))

    let identity = matrix_identity_double3x3
    for row in 0..<3 {
      for col in 0..<3 {
        #expect(abs(H[col][row] - identity[col][row]) < 1e-9)
      }
    }

    for p in src {
      let mapped = Homography.apply(H, to: p)
      #expect(abs(mapped.x - p.x) < 1e-9)
      #expect(abs(mapped.y - p.y) < 1e-9)
    }
  }

  @Test
  func homography_knownQuadCorrespondences_mapsAndInvertsCorrectly() throws {
    // Unit square -> an arbitrary convex quad (a typical "trapezoid" like
    // shape you'd see when a rectangle is viewed in perspective).
    let src: [SIMD2<Double>] = [
      SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1),
    ]
    let dst: [SIMD2<Double>] = [
      SIMD2(100, 500),
      SIMD2(400, 480),
      SIMD2(380, 100),
      SIMD2(120, 120),
    ]

    let H = try #require(Homography.homography(from: src, to: dst))

    for i in 0..<4 {
      let mapped = Homography.apply(H, to: src[i])
      #expect(abs(mapped.x - dst[i].x) < 1e-6)
      #expect(abs(mapped.y - dst[i].y) < 1e-6)
    }

    // H * inverse(H) ≈ identity
    let Hinv = simd_inverse(H)
    let product = H * Hinv
    let identity = matrix_identity_double3x3
    for row in 0..<3 {
      for col in 0..<3 {
        #expect(abs(product[col][row] - identity[col][row]) < 1e-9)
      }
    }

    // Forward then backward recovers the original point.
    let interior = SIMD2<Double>(0.37, 0.62)
    let forward = Homography.apply(H, to: interior)
    let backward = Homography.apply(Hinv, to: forward)
    #expect(abs(backward.x - interior.x) < 1e-9)
    #expect(abs(backward.y - interior.y) < 1e-9)
  }

  @Test
  func homography_collinearCorrespondences_returnsNil() {
    // Collinear source points -> degenerate DLT system.
    let src: [SIMD2<Double>] = [
      SIMD2(0, 0), SIMD2(1, 0), SIMD2(2, 0), SIMD2(3, 0),
    ]
    let dst: [SIMD2<Double>] = [
      SIMD2(0, 0), SIMD2(1, 1), SIMD2(2, 2), SIMD2(3, 3),
    ]

    let H = Homography.homography(from: src, to: dst)

    #expect(H == nil)
  }

  @Test
  func homography_wrongCorrespondenceCount_returnsNil() {
    let src: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(1, 0)]
    let dst: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(1, 0)]

    #expect(Homography.homography(from: src, to: dst) == nil)
  }
}
