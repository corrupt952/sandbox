import Testing

@testable import CoreMLEmbedCore

struct PredictOptionsTests {
  @Test func parse_WithAllArguments_ReturnsOptions() throws {
    let arguments = [
      "predict",
      "--model", "Shape.mlmodel",
      "--input", "images/",
      "--top-k", "5",
    ]

    let options = try PredictOptions.parse(arguments)

    #expect(options.modelPath == "Shape.mlmodel")
    #expect(options.inputPath == "images/")
    #expect(options.topK == 5)
  }

  @Test func parse_WithoutModel_ThrowsMissingModelError() {
    let arguments = ["predict", "--input", "a.png"]

    #expect(throws: PredictOptionsError.missingModel) {
      try PredictOptions.parse(arguments)
    }
  }

  @Test func parse_WithoutInput_ThrowsMissingInputError() {
    let arguments = ["predict", "--model", "m.mlmodel"]

    #expect(throws: PredictOptionsError.missingInput) {
      try PredictOptions.parse(arguments)
    }
  }

  @Test func parse_WithUnknownArgument_ThrowsUnknownArgumentError() {
    let arguments = ["predict", "--bogus"]

    #expect(throws: PredictOptionsError.unknownArgument("--bogus")) {
      try PredictOptions.parse(arguments)
    }
  }
}
