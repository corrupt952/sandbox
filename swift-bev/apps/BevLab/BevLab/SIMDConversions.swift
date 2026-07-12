//
//  SIMDConversions.swift
//  BevLab
//
//  Created by K@zuki. on 2026/07/12.
//

import simd

/// `simd`'s `Float` and `Double` matrix types don't provide direct
/// cross-precision initializers, so `ARFrame`'s `Float`-based camera
/// intrinsics/transform need explicit conversion before being handed to
/// `IPMCore`'s `Double`-based `PinholeCamera`.
extension simd_double3x3 {
  /// Converts a `Float` 3x3 matrix to `Double`, column by column.
  init(_ m: simd_float3x3) {
    self.init(
      SIMD3<Double>(m.columns.0),
      SIMD3<Double>(m.columns.1),
      SIMD3<Double>(m.columns.2))
  }
}

extension simd_double4x4 {
  /// Converts a `Float` 4x4 matrix to `Double`, column by column.
  init(_ m: simd_float4x4) {
    self.init(
      SIMD4<Double>(m.columns.0),
      SIMD4<Double>(m.columns.1),
      SIMD4<Double>(m.columns.2),
      SIMD4<Double>(m.columns.3))
  }
}
