import CoreGraphics
import CoreML
import CoreMLEmbedCore
import Foundation
import ImageIO

@main
struct PredictCommand {
  static func main() {
    do {
      try run()
    } catch let error as PredictOptionsError {
      FileHandle.standardError.write(Data("\(error)\n\(PredictOptions.usage)\n".utf8))
      exit(1)
    } catch {
      FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
      exit(1)
    }
  }

  static func run() throws {
    let options = try PredictOptions.parse(CommandLine.arguments)
    let modelURL = URL(fileURLWithPath: options.modelPath)

    let start = Date()
    let compiledURL: URL
    if modelURL.pathExtension == "mlmodelc" {
      compiledURL = modelURL
    } else {
      compiledURL = try MLModel.compileModel(at: modelURL)
      print(
        String(
          format: "Compiled in %.2fs: %@", Date().timeIntervalSince(start),
          compiledURL.lastPathComponent))
    }

    let model = try MLModel(contentsOf: compiledURL)
    guard let (inputName, constraint) = imageInput(of: model) else {
      FileHandle.standardError.write(Data("Model has no image input\n".utf8))
      exit(1)
    }

    let inputURL = URL(fileURLWithPath: options.inputPath)
    var isDirectory: ObjCBool = false
    FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDirectory)

    if isDirectory.boolValue {
      try predictLabeledDirectory(
        model: model,
        inputName: inputName,
        constraint: constraint,
        rootURL: inputURL,
        topK: options.topK
      )
    } else {
      let (label, lines) = try predict(
        model: model,
        inputName: inputName,
        constraint: constraint,
        imageURL: inputURL,
        topK: options.topK
      )
      print("Prediction: \(label)")
      for line in lines {
        print("  \(line)")
      }
    }
  }

  static func imageInput(of model: MLModel) -> (String, MLImageConstraint)? {
    for (name, description) in model.modelDescription.inputDescriptionsByName {
      if let constraint = description.imageConstraint {
        return (name, constraint)
      }
    }
    return nil
  }

  static func predict(
    model: MLModel,
    inputName: String,
    constraint: MLImageConstraint,
    imageURL: URL,
    topK: Int
  ) throws -> (label: String, lines: [String]) {
    let featureValue = try MLFeatureValue(imageAt: imageURL, constraint: constraint)
    let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: featureValue])
    let output = try model.prediction(from: provider)

    let description = model.modelDescription
    let label =
      description.predictedFeatureName
      .flatMap { output.featureValue(for: $0)?.stringValue } ?? "?"
    let probabilities =
      description.predictedProbabilitiesName
      .flatMap { output.featureValue(for: $0)?.dictionaryValue as? [String: Double] } ?? [:]

    return (label, PredictionFormatter.topLines(probabilities: probabilities, topK: topK))
  }

  static func predictLabeledDirectory(
    model: MLModel,
    inputName: String,
    constraint: MLImageConstraint,
    rootURL: URL,
    topK: Int
  ) throws {
    let fileManager = FileManager.default
    var tally = PredictionTally()
    let start = Date()

    let labelDirectories =
      try fileManager
      .contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey])
      .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }

    for directoryURL in labelDirectories {
      let expected = directoryURL.lastPathComponent
      let imageURLs =
        try fileManager
        .contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

      for imageURL in imageURLs {
        let (predicted, _) = try predict(
          model: model,
          inputName: inputName,
          constraint: constraint,
          imageURL: imageURL,
          topK: topK
        )
        tally.add(predicted: predicted, expected: expected)
        if predicted != expected {
          print("MISS \(imageURL.lastPathComponent): expected \(expected), got \(predicted)")
        }
      }
    }

    let elapsed = Date().timeIntervalSince(start)
    let perImage = tally.total == 0 ? 0 : elapsed / Double(tally.total) * 1000
    print(
      String(
        format: "Accuracy: %.1f%% (%d/%d), %.1fms/image",
        tally.accuracy * 100,
        tally.correct,
        tally.total,
        perImage
      ))
  }
}
