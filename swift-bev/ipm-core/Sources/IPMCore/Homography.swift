import Foundation
import simd

/// Planar homography utilities: estimation from 4 point correspondences (DLT),
/// point transformation with perspective (w) divide.
public enum Homography {

  /// Solves for the 3x3 homography `H` such that `apply(H, src[i]) ≈ dst[i]`
  /// for the 4 given correspondences, using the standard 8-DOF Direct Linear
  /// Transform (DLT) with `h33` fixed to 1.
  ///
  /// Requires exactly 4 correspondences (the classic 4-point perspective
  /// transform used for IPM / bird's-eye-view rectification). Returns `nil`
  /// if the correspondences are degenerate (e.g. collinear points, or the
  /// resulting 8x8 system is singular).
  ///
  /// - Parameters:
  ///   - src: 4 source points.
  ///   - dst: 4 destination points, in the same order as `src`.
  /// - Returns: The homography matrix `H` (row-major via `simd_double3x3`
  ///   column convention, see `apply`), or `nil` if it cannot be solved.
  public static func homography(from src: [SIMD2<Double>], to dst: [SIMD2<Double>])
    -> simd_double3x3?
  {
    guard src.count == 4, dst.count == 4 else { return nil }

    // For each correspondence (x, y) -> (u, v), the DLT gives two rows:
    //   x*h1 + y*h2 + h3 - u*x*h7 - u*y*h8 - u*h9 = 0   (with h9 = 1)
    //   x*h4 + y*h5 + h6 - v*x*h7 - v*y*h8 - v*h9 = 0
    // We solve for h1..h8 (h9 = 1) via an 8x8 linear system A * h = b.
    var A = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 8)
    var b = [Double](repeating: 0, count: 8)

    for i in 0..<4 {
      let x = src[i].x
      let y = src[i].y
      let u = dst[i].x
      let v = dst[i].y

      let row0 = 2 * i
      let row1 = 2 * i + 1

      A[row0] = [x, y, 1, 0, 0, 0, -u * x, -u * y]
      b[row0] = u

      A[row1] = [0, 0, 0, x, y, 1, -v * x, -v * y]
      b[row1] = v
    }

    guard let h = solveLinearSystem(A: A, b: b) else { return nil }

    // simd_double3x3 is column-major: matrix.columns.(0/1/2) are columns.
    // We want H * [x, y, 1]^T to compute [u', v', w']^T with
    //   u' = h1*x + h2*y + h3
    //   v' = h4*x + h5*y + h6
    //   w' = h7*x + h8*y + 1
    // so row 0 = (h1, h2, h3), row 1 = (h4, h5, h6), row 2 = (h7, h8, 1).
    let row0 = SIMD3<Double>(h[0], h[1], h[2])
    let row1 = SIMD3<Double>(h[3], h[4], h[5])
    let row2 = SIMD3<Double>(h[6], h[7], 1)

    // Build from rows: simd_double3x3(rows:) constructs from row vectors.
    let H = simd_double3x3(rows: [row0, row1, row2])
    return H
  }

  /// Applies a homography `H` to a 2D point using homogeneous coordinates
  /// with a perspective (w) divide. Points that map to `w ≈ 0` return the
  /// raw (un-normalized) coordinates to avoid division by zero.
  public static func apply(_ H: simd_double3x3, to p: SIMD2<Double>) -> SIMD2<Double> {
    let hp = H * SIMD3<Double>(p.x, p.y, 1)
    guard abs(hp.z) > 1e-12 else { return SIMD2<Double>(hp.x, hp.y) }
    return SIMD2<Double>(hp.x / hp.z, hp.y / hp.z)
  }

  /// Solves an 8x8 linear system `A * x = b` via Gaussian elimination with
  /// partial pivoting. Returns `nil` if `A` is (numerically) singular.
  private static func solveLinearSystem(A: [[Double]], b: [Double]) -> [Double]? {
    let n = b.count
    var M = A
    var rhs = b

    for col in 0..<n {
      // Partial pivot.
      var pivotRow = col
      var maxVal = abs(M[col][col])
      for r in (col + 1)..<n {
        if abs(M[r][col]) > maxVal {
          maxVal = abs(M[r][col])
          pivotRow = r
        }
      }
      if maxVal < 1e-12 {
        return nil
      }
      if pivotRow != col {
        M.swapAt(col, pivotRow)
        rhs.swapAt(col, pivotRow)
      }

      let pivot = M[col][col]
      for r in 0..<n where r != col {
        let factor = M[r][col] / pivot
        guard factor != 0 else { continue }
        for c in col..<n {
          M[r][c] -= factor * M[col][c]
        }
        rhs[r] -= factor * rhs[col]
      }
    }

    var x = [Double](repeating: 0, count: n)
    for i in 0..<n {
      x[i] = rhs[i] / M[i][i]
    }
    return x
  }
}
