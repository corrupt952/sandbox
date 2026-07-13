import Foundation
import ImageClassifierCore

@main
struct DatasetGenCommand {
  @MainActor
  static func main() throws {
    let options = try Options.parse(CommandLine.arguments)
    let renderer = SyntheticSampleRenderer()
    var generator = SplitMix64RandomNumberGenerator(seed: options.seed)
    let writer = DatasetWriter(rootURL: options.outputURL)

    for shape in SyntheticShape.allCases {
      for index in 0..<options.count {
        guard let image = renderer.render(shape: shape, using: &generator) else {
          fatalError("Failed to render \(shape.label) #\(index)")
        }
        try writer.write(image, label: shape.label, index: index)
      }
      print("\(shape.label): \(options.count) images")
    }

    print("Done: \(options.outputURL.path)")
  }
}

struct Options {
  var outputURL: URL
  var count: Int
  var seed: UInt64

  static func parse(_ arguments: [String]) throws -> Options {
    var output = "dataset"
    var count = 30
    var seed: UInt64 = 42

    var iterator = arguments.dropFirst().makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--output":
        output = iterator.next() ?? output
      case "--count":
        count = Int(iterator.next() ?? "") ?? count
      case "--seed":
        seed = UInt64(iterator.next() ?? "") ?? seed
      case "--help", "-h":
        print("Usage: datasetgen [--output DIR] [--count N] [--seed N]")
        exit(0)
      default:
        FileHandle.standardError.write(Data("Unknown argument: \(argument)\n".utf8))
        exit(1)
      }
    }

    return Options(
      outputURL: URL(fileURLWithPath: output),
      count: count,
      seed: seed
    )
  }
}
