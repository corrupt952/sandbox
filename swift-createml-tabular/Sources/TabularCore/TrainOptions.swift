import Foundation

public enum TrainTask: String, Sendable {
  case classification
  case regression
}

public enum TrainModel: String, Sendable {
  case boostedTree
  case linear
}

public enum TrainOptionsError: Error, Equatable {
  case missingData
  case missingTarget
  case missingFeatures
  case invalidTask(String)
  case invalidModel(String)
  case unknownArgument(String)
}

public struct TrainOptions: Sendable {
  public var dataPath: String
  public var target: String
  public var features: [String]
  public var task: TrainTask
  public var model: TrainModel
  public var trainFraction: Double
  public var seed: UInt64

  public static let usage = """
    Usage: train --data CSV --target COLUMN --features COL1,COL2,... \
    [--task classification|regression] [--model boostedTree|linear] \
    [--split 0.8] [--seed 42]
    """

  public static func parse(_ arguments: [String]) throws -> TrainOptions {
    var dataPath: String?
    var target: String?
    var features: [String] = []
    var task = TrainTask.classification
    var model = TrainModel.boostedTree
    var trainFraction = 0.8
    var seed: UInt64 = 42

    var iterator = arguments.dropFirst().makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--data":
        dataPath = iterator.next()
      case "--target":
        target = iterator.next()
      case "--features":
        features = (iterator.next() ?? "")
          .split(separator: ",")
          .map { $0.trimmingCharacters(in: .whitespaces) }
          .filter { !$0.isEmpty }
      case "--task":
        let raw = iterator.next() ?? ""
        guard let parsed = TrainTask(rawValue: raw) else {
          throw TrainOptionsError.invalidTask(raw)
        }
        task = parsed
      case "--model":
        let raw = iterator.next() ?? ""
        guard let parsed = TrainModel(rawValue: raw) else {
          throw TrainOptionsError.invalidModel(raw)
        }
        model = parsed
      case "--split":
        trainFraction = Double(iterator.next() ?? "") ?? trainFraction
      case "--seed":
        seed = UInt64(iterator.next() ?? "") ?? seed
      default:
        throw TrainOptionsError.unknownArgument(argument)
      }
    }

    guard let dataPath else {
      throw TrainOptionsError.missingData
    }
    guard let target else {
      throw TrainOptionsError.missingTarget
    }
    guard !features.isEmpty else {
      throw TrainOptionsError.missingFeatures
    }

    return TrainOptions(
      dataPath: dataPath,
      target: target,
      features: features,
      task: task,
      model: model,
      trainFraction: trainFraction,
      seed: seed
    )
  }
}
