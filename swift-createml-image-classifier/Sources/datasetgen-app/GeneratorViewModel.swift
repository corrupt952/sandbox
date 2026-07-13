import Foundation
import ImageClassifierCore
import Observation

@MainActor
@Observable
final class GeneratorViewModel {
  // MARK: - Properties

  var classes: [DatasetClassSpec] = [
    DatasetClassSpec(label: "cat", prompt: "a cute cat sitting"),
    DatasetClassSpec(label: "dog", prompt: "a happy dog running"),
    DatasetClassSpec(label: "car", prompt: "a small car on a road"),
  ]
  var styleNames: [String] = []
  var selectedStyleIndex = 0
  var countPerClass = 20
  var outputDirectory: URL?
  var isGenerating = false
  var statusMessage = ""
  var errorMessage: String?

  // MARK: - Dependencies

  @ObservationIgnored
  private let repository: ImageGenerationRepositoryProtocol

  @ObservationIgnored
  private let generateDatasetUseCase: GenerateDatasetUseCaseProtocol

  // MARK: - Initialization

  init(repository: ImageGenerationRepositoryProtocol = ImagePlaygroundRepository()) {
    self.repository = repository
    generateDatasetUseCase = GenerateDatasetUseCase(repository: repository)
  }

  // MARK: - Public methods

  func loadStyles() {
    Task {
      do {
        styleNames = try await repository.availableStyleNames()
        statusMessage = "Ready (\(styleNames.count) styles available)"
      } catch {
        errorMessage = "ImageCreator unavailable: \(error)"
      }
    }
  }

  func addClass() {
    classes.append(DatasetClassSpec(label: "", prompt: ""))
  }

  func removeClass(_ spec: DatasetClassSpec) {
    classes.removeAll { $0.id == spec.id }
  }

  func generate() {
    guard let outputDirectory else {
      errorMessage = "Choose an output directory first"
      return
    }

    Task {
      isGenerating = true
      errorMessage = nil
      defer { isGenerating = false }

      do {
        let writer = DatasetWriter(rootURL: outputDirectory)
        try await generateDatasetUseCase.execute(
          classes: classes,
          styleIndex: selectedStyleIndex,
          countPerClass: countPerClass,
          writer: writer
        ) { label, written in
          self.statusMessage = "\(label): \(written)/\(self.countPerClass)"
        }
        statusMessage = "Done: \(outputDirectory.path)"
      } catch {
        errorMessage = "Generation failed: \(error)"
      }
    }
  }
}
