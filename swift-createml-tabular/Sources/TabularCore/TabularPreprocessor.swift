import Foundation
import TabularData

public enum TabularPreprocessorError: Error, Equatable {
  case missingColumn(String)
}

public enum TabularPreprocessor {
  /// Returns a frame containing only the given columns, in the given order.
  public static func selecting(_ frame: DataFrame, columns: [String]) throws -> DataFrame {
    var result = DataFrame()
    for name in columns {
      guard frame.containsColumn(name) else {
        throw TabularPreprocessorError.missingColumn(name)
      }
      result.append(column: frame[name])
    }
    return result
  }

  /// Fills missing values in a numeric column with the column median.
  public static func imputingMedian(_ frame: DataFrame, column: String) throws -> DataFrame {
    guard frame.containsColumn(column) else {
      throw TabularPreprocessorError.missingColumn(column)
    }

    var result = frame
    let values = result[column].compactMap { $0 as? Double }.sorted()
    guard !values.isEmpty else {
      return result
    }

    let median = values[values.count / 2]
    result.transformColumn(column) { (value: Double?) -> Double in
      value ?? median
    }
    return result
  }

  /// Removes rows that contain a nil in any column.
  public static func droppingRowsWithNil(_ frame: DataFrame) -> DataFrame {
    let columnCount = frame.columns.count
    let slice = frame.filter { row in
      !(0..<columnCount).contains { row[$0] == nil }
    }
    return DataFrame(slice)
  }

  /// Deterministic shuffled train/test split.
  public static func split(
    _ frame: DataFrame,
    trainFraction: Double,
    seed: UInt64
  ) -> (train: DataFrame, test: DataFrame) {
    var generator = SplitMix64RandomNumberGenerator(seed: seed)
    let indices = Array(0..<frame.rows.count).shuffled(using: &generator)
    let trainCount = Int(Double(frame.rows.count) * trainFraction)
    let trainIndices = Set(indices.prefix(trainCount))

    let trainSlice = frame.filter { trainIndices.contains($0.index) }
    let testSlice = frame.filter { !trainIndices.contains($0.index) }

    return (DataFrame(trainSlice), DataFrame(testSlice))
  }
}
