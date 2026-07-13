import Foundation

public enum TrainOptionsError: Error, Equatable {
  case invalidDevice(String)
  case unknownArgument(String)
}

public enum TrainDevice: String, Sendable {
  case cpu
  case gpu
}

public struct TrainOptions: Sendable {
  /// Data files are downloaded from here when absent. This is image data, not
  /// executable code, and is parsed by the bounded IDXParser — but it is still
  /// a third-party host, so it is overridable via --base-url.
  public static let defaultBaseURL = "https://raw.githubusercontent.com/fgnt/mnist/master/"

  public var dataPath: String
  public var baseURL: String
  public var epochs: Int
  public var batchSize: Int
  public var learningRate: Float
  public var seed: UInt64
  public var device: TrainDevice

  public static let usage = """
    Usage: mnist-train [--data DIR] [--base-url URL] [--epochs 5] \
    [--batch-size 256] [--learning-rate 0.1] [--seed 0] [--device gpu|cpu]

    Note: --device gpu requires an xcodebuild-built binary (Scripts/run.sh); \
    plain `swift run` cannot bundle the Metal shaders and only supports --device cpu.
    """

  public static func parse(_ arguments: [String]) throws -> TrainOptions {
    var dataPath = "data"
    var baseURL = defaultBaseURL
    var epochs = 5
    var batchSize = 256
    var learningRate: Float = 0.1
    var seed: UInt64 = 0
    var device = TrainDevice.gpu

    var iterator = arguments.dropFirst().makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--data":
        dataPath = iterator.next() ?? dataPath
      case "--base-url":
        baseURL = iterator.next() ?? baseURL
      case "--epochs":
        epochs = Int(iterator.next() ?? "") ?? epochs
      case "--batch-size":
        batchSize = Int(iterator.next() ?? "") ?? batchSize
      case "--learning-rate":
        learningRate = Float(iterator.next() ?? "") ?? learningRate
      case "--seed":
        seed = UInt64(iterator.next() ?? "") ?? seed
      case "--device":
        let raw = iterator.next() ?? ""
        guard let parsed = TrainDevice(rawValue: raw) else {
          throw TrainOptionsError.invalidDevice(raw)
        }
        device = parsed
      default:
        throw TrainOptionsError.unknownArgument(argument)
      }
    }

    return TrainOptions(
      dataPath: dataPath,
      baseURL: baseURL,
      epochs: epochs,
      batchSize: batchSize,
      learningRate: learningRate,
      seed: seed,
      device: device
    )
  }
}
