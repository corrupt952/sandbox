import Testing

@testable import TabularCore

struct TrainOptionsTests {
  @Test func parse_WithAllArguments_ReturnsOptions() throws {
    let arguments = [
      "train",
      "--data", "titanic.csv",
      "--target", "Survived",
      "--features", "Pclass, Sex ,Age",
      "--task", "classification",
      "--model", "linear",
      "--split", "0.7",
      "--seed", "7",
    ]

    let options = try TrainOptions.parse(arguments)

    #expect(options.dataPath == "titanic.csv")
    #expect(options.target == "Survived")
    #expect(options.features == ["Pclass", "Sex", "Age"])
    #expect(options.task == .classification)
    #expect(options.model == .linear)
    #expect(options.trainFraction == 0.7)
    #expect(options.seed == 7)
  }

  @Test func parse_WithoutData_ThrowsMissingDataError() {
    let arguments = ["train", "--target", "y", "--features", "x"]

    #expect(throws: TrainOptionsError.missingData) {
      try TrainOptions.parse(arguments)
    }
  }

  @Test func parse_WithoutTarget_ThrowsMissingTargetError() {
    let arguments = ["train", "--data", "d.csv", "--features", "x"]

    #expect(throws: TrainOptionsError.missingTarget) {
      try TrainOptions.parse(arguments)
    }
  }

  @Test func parse_WithoutFeatures_ThrowsMissingFeaturesError() {
    let arguments = ["train", "--data", "d.csv", "--target", "y"]

    #expect(throws: TrainOptionsError.missingFeatures) {
      try TrainOptions.parse(arguments)
    }
  }

  @Test func parse_WithInvalidTask_ThrowsInvalidTaskError() {
    let arguments = [
      "train", "--data", "d.csv", "--target", "y", "--features", "x",
      "--task", "clustering",
    ]

    #expect(throws: TrainOptionsError.invalidTask("clustering")) {
      try TrainOptions.parse(arguments)
    }
  }

  @Test func parse_WithUnknownArgument_ThrowsUnknownArgumentError() {
    let arguments = ["train", "--bogus"]

    #expect(throws: TrainOptionsError.unknownArgument("--bogus")) {
      try TrainOptions.parse(arguments)
    }
  }
}
