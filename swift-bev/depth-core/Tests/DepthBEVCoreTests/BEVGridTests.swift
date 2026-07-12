import Testing
import simd

@testable import DepthBEVCore

@Suite
struct BEVGridTests {
  func makeGrid(groundY: Double = 0) -> BEVGrid {
    BEVGrid(origin: SIMD2<Double>(-2, -2), cellSize: 1, columns: 4, rows: 4, groundY: groundY)
  }

  @Test
  func add_pointInsideExtent_landsInExpectedCell() {
    var grid = makeGrid()

    grid.add(SIMD3<Double>(-1.5, 0, -1.5))

    #expect(grid.occupancy(column: 0, row: 0) == 1)
  }

  @Test
  func add_multiplePointsInSameCell_incrementsMaxHeight() {
    var grid = makeGrid()

    grid.add(SIMD3<Double>(-1.5, 0.2, -1.5))
    grid.add(SIMD3<Double>(-1.6, 0.9, -1.4))
    grid.add(SIMD3<Double>(-1.4, 0.5, -1.6))

    #expect(abs(grid.height(column: 0, row: 0) - 0.9) < 1e-12)
  }

  @Test
  func add_multiplePointsInSameCell_accumulatesOccupancyCount() {
    var grid = makeGrid()

    grid.add(SIMD3<Double>(0.1, 0, 0.1))
    grid.add(SIMD3<Double>(0.2, 0, 0.2))
    grid.add(SIMD3<Double>(0.3, 0, 0.3))

    #expect(grid.occupancy(column: 2, row: 2) == 3)
  }

  @Test(
    arguments: [
      SIMD3<Double>(-10, 0, 0),
      SIMD3<Double>(10, 0, 0),
      SIMD3<Double>(0, 0, -10),
      SIMD3<Double>(0, 0, 10),
    ]
  )
  func add_pointOutsideExtent_isIgnored(point: SIMD3<Double>) {
    var grid = makeGrid()

    grid.add(point)

    let totalOccupancy = grid.occupancyGrid.flatMap { $0 }.reduce(0, +)
    #expect(totalOccupancy == 0)
  }

  @Test
  func add_pointAboveGroundY_measuresHeightRelativeToGround() {
    var grid = makeGrid(groundY: 1.0)

    grid.add(SIMD3<Double>(0, 1.75, 0))

    #expect(abs(grid.height(column: 2, row: 2) - 0.75) < 1e-12)
  }

  @Test
  func add_pointBelowGroundY_clampsHeightToZero() {
    var grid = makeGrid(groundY: 1.0)

    grid.add(SIMD3<Double>(0, 0.2, 0))

    #expect(abs(grid.height(column: 2, row: 2) - 0) < 1e-12)
  }

  @Test
  func cellIndex_pointOutsideExtent_returnsNil() {
    let grid = makeGrid()

    let index = grid.cellIndex(x: 100, z: 100)

    #expect(index == nil)
  }

  @Test
  func addWorldPoints_batchOfPoints_addsEachPoint() {
    var grid = makeGrid()

    grid.add(worldPoints: [
      SIMD3<Double>(-1.5, 0, -1.5),
      SIMD3<Double>(-1.5, 0, -1.5),
    ])

    #expect(grid.occupancy(column: 0, row: 0) == 2)
  }
}
