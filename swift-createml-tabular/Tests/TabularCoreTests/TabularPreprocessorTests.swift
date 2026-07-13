import TabularData
import Testing

@testable import TabularCore

struct TabularPreprocessorTests {
  private func makeFrame() -> DataFrame {
    var frame = DataFrame()
    frame.append(column: Column(name: "age", contents: [20.0, nil, 40.0, 60.0]))
    frame.append(column: Column(name: "label", contents: [0, 1, 0, 1]))
    frame.append(column: Column<String>(name: "name", contents: ["a", "b", "c", "d"]))
    return frame
  }

  @Test func selecting_WithValidColumns_KeepsOnlyThoseColumns() throws {
    let frame = makeFrame()

    let result = try TabularPreprocessor.selecting(frame, columns: ["label", "age"])

    #expect(result.columns.map(\.name) == ["label", "age"])
    #expect(result.rows.count == 4)
  }

  @Test func selecting_WithMissingColumn_ThrowsMissingColumnError() {
    let frame = makeFrame()

    #expect(throws: TabularPreprocessorError.missingColumn("bogus")) {
      try TabularPreprocessor.selecting(frame, columns: ["bogus"])
    }
  }

  @Test func imputingMedian_WithMissingValue_FillsMedian() throws {
    let frame = makeFrame()

    let result = try TabularPreprocessor.imputingMedian(frame, column: "age")

    let ages = result["age"].compactMap { $0 as? Double }
    #expect(ages == [20.0, 40.0, 40.0, 60.0])
  }

  @Test func droppingRowsWithNil_RemovesIncompleteRows() {
    let frame = makeFrame()

    let result = TabularPreprocessor.droppingRowsWithNil(frame)

    #expect(result.rows.count == 3)
    let names = result["name"].compactMap { $0 as? String }
    #expect(names == ["a", "c", "d"])
  }

  @Test func split_WithFraction_ProducesDisjointSizes() {
    let frame = makeFrame()

    let (train, test) = TabularPreprocessor.split(frame, trainFraction: 0.75, seed: 1)

    #expect(train.rows.count == 3)
    #expect(test.rows.count == 1)
  }

  @Test func split_WithSameSeed_IsDeterministic() {
    let frame = makeFrame()

    let (trainA, _) = TabularPreprocessor.split(frame, trainFraction: 0.5, seed: 9)
    let (trainB, _) = TabularPreprocessor.split(frame, trainFraction: 0.5, seed: 9)

    let namesA = trainA["name"].compactMap { $0 as? String }
    let namesB = trainB["name"].compactMap { $0 as? String }
    #expect(namesA == namesB)
  }
}
