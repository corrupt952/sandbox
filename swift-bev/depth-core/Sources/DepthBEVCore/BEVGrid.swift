import Foundation
import simd

/// A top-down occupancy / height grid over a metric (X, Z) region of the
/// world ground plane.
///
/// The grid covers a rectangular region of the world's X-Z plane, starting
/// at `origin` (the world (X, Z) of the grid's (0, 0) corner, i.e. cell
/// `(column: 0, row: 0)`) and extending `columns * cellSize` meters along X
/// and `rows * cellSize` meters along Z. Each cell tracks how many points
/// landed in it (occupancy) and the maximum height above `groundY` seen
/// among those points.
///
/// Confidence filtering is intentionally out of scope here: callers should
/// skip low-confidence depth samples before calling `add(_:)`.
public struct BEVGrid {
  /// World (X, Z) of the grid's (column: 0, row: 0) corner.
  public var origin: SIMD2<Double>

  /// Size of a single square cell, in meters.
  public var cellSize: Double

  /// Number of columns (extent along world X).
  public var columns: Int

  /// Number of rows (extent along world Z).
  public var rows: Int

  /// World Y of the ground plane; heights are measured relative to this.
  public var groundY: Double

  private var occupancyCounts: [[Int]]
  private var maxHeights: [[Double]]

  public init(origin: SIMD2<Double>, cellSize: Double, columns: Int, rows: Int, groundY: Double) {
    self.origin = origin
    self.cellSize = cellSize
    self.columns = columns
    self.rows = rows
    self.groundY = groundY
    self.occupancyCounts = Array(repeating: Array(repeating: 0, count: columns), count: rows)
    self.maxHeights = Array(repeating: Array(repeating: 0, count: columns), count: rows)
  }

  // MARK: - Indexing

  /// Maps a world (x, z) coordinate to a cell index, or `nil` if it falls
  /// outside the grid's extent.
  public func cellIndex(x: Double, z: Double) -> (column: Int, row: Int)? {
    let localX = x - origin.x
    let localZ = z - origin.y

    guard localX >= 0, localZ >= 0 else {
      return nil
    }

    let column = Int(localX / cellSize)
    let row = Int(localZ / cellSize)

    guard column >= 0, column < columns, row >= 0, row < rows else {
      return nil
    }

    return (column, row)
  }

  // MARK: - Mutation

  /// Bins a world point by its (X, Z) coordinates into a cell. Points
  /// outside the grid's extent are ignored. Updates the cell's occupancy
  /// count and its max height above `groundY` (clamped at >= 0).
  public mutating func add(_ worldPoint: SIMD3<Double>) {
    guard let index = cellIndex(x: worldPoint.x, z: worldPoint.z) else {
      return
    }

    let height = max(0, worldPoint.y - groundY)
    occupancyCounts[index.row][index.column] += 1
    maxHeights[index.row][index.column] = max(maxHeights[index.row][index.column], height)
  }

  /// Batch helper that adds multiple world points.
  public mutating func add(worldPoints: [SIMD3<Double>]) {
    for point in worldPoints {
      add(point)
    }
  }

  // MARK: - Readouts

  /// Number of points that landed in the given cell.
  public func occupancy(column: Int, row: Int) -> Int {
    occupancyCounts[row][column]
  }

  /// Maximum height above `groundY` seen among points in the given cell.
  public func height(column: Int, row: Int) -> Double {
    maxHeights[row][column]
  }

  /// The full occupancy grid, indexed as `[row][column]`.
  public var occupancyGrid: [[Int]] {
    occupancyCounts
  }

  /// The full height grid, indexed as `[row][column]`.
  public var heightGrid: [[Double]] {
    maxHeights
  }
}
