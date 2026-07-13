import CoreGraphics
import Foundation

public enum GenerateDatasetError: Error {
  case emptyLabel
  case emptyPrompt
}

@MainActor
public protocol GenerateDatasetUseCaseProtocol {
  func execute(
    classes: [DatasetClassSpec],
    styleIndex: Int,
    countPerClass: Int,
    writer: DatasetWriterProtocol,
    onProgress: (String, Int) -> Void
  ) async throws
}

@MainActor
public final class GenerateDatasetUseCase: GenerateDatasetUseCaseProtocol {
  private let repository: ImageGenerationRepositoryProtocol
  private let variator: PromptVariator
  private var generator: any RandomNumberGenerator

  public init(
    repository: ImageGenerationRepositoryProtocol,
    variator: PromptVariator = PromptVariator(),
    generator: any RandomNumberGenerator = SystemRandomNumberGenerator()
  ) {
    self.repository = repository
    self.variator = variator
    self.generator = generator
  }

  public func execute(
    classes: [DatasetClassSpec],
    styleIndex: Int,
    countPerClass: Int,
    writer: DatasetWriterProtocol,
    onProgress: (String, Int) -> Void
  ) async throws {
    for spec in classes {
      let label = spec.label.trimmingCharacters(in: .whitespaces)
      let prompt = spec.prompt.trimmingCharacters(in: .whitespaces)

      guard !label.isEmpty else {
        throw GenerateDatasetError.emptyLabel
      }
      guard !prompt.isEmpty else {
        throw GenerateDatasetError.emptyPrompt
      }

      // One varied prompt per image: identical prompts would yield
      // identical images (ImageCreator generation is deterministic).
      var written = 0
      while written < countPerClass {
        let variedPrompt = variator.variation(of: prompt, using: &generator)
        let images = try await repository.generateImages(
          prompt: variedPrompt,
          styleIndex: styleIndex,
          count: 1
        )

        guard let image = images.first else {
          break
        }

        try writer.write(image, label: label, index: written)
        written += 1
        onProgress(label, written)
      }
    }
  }
}
