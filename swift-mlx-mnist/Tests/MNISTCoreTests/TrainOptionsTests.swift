import Testing

@testable import MNISTCore

struct TrainOptionsTests {
  @Test func parse_WithNoArguments_ReturnsDefaults() throws {
    let options = try TrainOptions.parse(["mnist-train"])

    #expect(options.dataPath == "data")
    #expect(options.baseURL == TrainOptions.defaultBaseURL)
    #expect(options.epochs == 5)
    #expect(options.batchSize == 256)
    #expect(options.learningRate == 0.1)
    #expect(options.seed == 0)
  }

  @Test func parse_WithAllArguments_ReturnsOptions() throws {
    let arguments = [
      "mnist-train",
      "--data", "/tmp/mnist",
      "--base-url", "https://example.com/mnist/",
      "--epochs", "3",
      "--batch-size", "128",
      "--learning-rate", "0.01",
      "--seed", "42",
    ]

    let options = try TrainOptions.parse(arguments)

    #expect(options.dataPath == "/tmp/mnist")
    #expect(options.baseURL == "https://example.com/mnist/")
    #expect(options.epochs == 3)
    #expect(options.batchSize == 128)
    #expect(options.learningRate == 0.01)
    #expect(options.seed == 42)
  }

  @Test func parse_WithUnknownArgument_ThrowsUnknownArgumentError() {
    #expect(throws: TrainOptionsError.unknownArgument("--bogus")) {
      try TrainOptions.parse(["mnist-train", "--bogus"])
    }
  }
}
