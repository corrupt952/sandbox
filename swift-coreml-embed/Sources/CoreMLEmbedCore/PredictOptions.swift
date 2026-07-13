import Foundation

public enum PredictOptionsError: Error, Equatable {
  case missingModel
  case missingInput
  case unknownArgument(String)
}

public struct PredictOptions: Sendable {
  public var modelPath: String
  public var inputPath: String
  public var topK: Int

  public static let usage = """
    Usage: predict --model MODEL.mlmodel --input IMAGE_OR_LABELED_DIR [--top-k 3]
    """

  public static func parse(_ arguments: [String]) throws -> PredictOptions {
    var modelPath: String?
    var inputPath: String?
    var topK = 3

    var iterator = arguments.dropFirst().makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--model":
        modelPath = iterator.next()
      case "--input":
        inputPath = iterator.next()
      case "--top-k":
        topK = Int(iterator.next() ?? "") ?? topK
      default:
        throw PredictOptionsError.unknownArgument(argument)
      }
    }

    guard let modelPath else {
      throw PredictOptionsError.missingModel
    }
    guard let inputPath else {
      throw PredictOptionsError.missingInput
    }

    return PredictOptions(modelPath: modelPath, inputPath: inputPath, topK: topK)
  }
}
