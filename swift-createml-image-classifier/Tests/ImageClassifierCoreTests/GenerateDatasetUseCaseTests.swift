import CoreGraphics
import Foundation
import Testing

@testable import ImageClassifierCore

enum TestError: Error {
  case generic
}

@MainActor
final class MockImageGenerationRepository: ImageGenerationRepositoryProtocol {
  // MARK: - Call tracking

  var generateImagesCallCount = 0
  var generateImagesParameters: [(prompt: String, styleIndex: Int, count: Int)] = []

  // MARK: - Return value control

  var imagePerRequest: CGImage?

  // MARK: - Error control

  var shouldThrowError = false
  var errorToThrow: Error = TestError.generic

  func availableStyleNames() async throws -> [String] {
    ["animation"]
  }

  func generateImages(prompt: String, styleIndex: Int, count: Int) async throws -> [CGImage] {
    generateImagesCallCount += 1
    generateImagesParameters.append((prompt, styleIndex, count))

    if shouldThrowError {
      throw errorToThrow
    }

    guard let imagePerRequest else {
      return []
    }
    return Array(repeating: imagePerRequest, count: count)
  }
}

@MainActor
final class MockDatasetWriter: DatasetWriterProtocol {
  var writeCallCount = 0
  var writtenLabels: [String] = []
  var writtenIndices: [Int] = []

  func write(_ image: CGImage, label: String, index: Int) throws {
    writeCallCount += 1
    writtenLabels.append(label)
    writtenIndices.append(index)
  }
}

@MainActor
struct GenerateDatasetUseCaseTests {
  let mockRepository: MockImageGenerationRepository
  let mockWriter: MockDatasetWriter
  let sut: GenerateDatasetUseCase

  init() throws {
    mockRepository = MockImageGenerationRepository()
    mockWriter = MockDatasetWriter()
    sut = GenerateDatasetUseCase(
      repository: mockRepository,
      generator: SplitMix64RandomNumberGenerator(seed: 42)
    )

    let renderer = SyntheticSampleRenderer(canvasSize: 8)
    var generator = SplitMix64RandomNumberGenerator(seed: 1)
    mockRepository.imagePerRequest = try #require(
      renderer.render(shape: .circle, using: &generator)
    )
  }

  @Test func execute_WithSingleClass_WritesRequestedCount() async throws {
    let classes = [DatasetClassSpec(label: "cat", prompt: "a cat")]

    try await sut.execute(
      classes: classes,
      styleIndex: 0,
      countPerClass: 10,
      writer: mockWriter
    ) { _, _ in }

    #expect(mockWriter.writeCallCount == 10)
    #expect(mockWriter.writtenLabels.allSatisfy { $0 == "cat" })
    #expect(mockWriter.writtenIndices == Array(0..<10))
  }

  @Test func execute_RequestsOneImagePerVariedPrompt() async throws {
    let classes = [DatasetClassSpec(label: "dog", prompt: "a dog")]

    try await sut.execute(
      classes: classes,
      styleIndex: 0,
      countPerClass: 10,
      writer: mockWriter
    ) { _, _ in }

    let parameters = mockRepository.generateImagesParameters
    #expect(parameters.map(\.count) == Array(repeating: 1, count: 10))
    #expect(parameters.allSatisfy { $0.prompt.hasPrefix("a dog") })
    #expect(Set(parameters.map(\.prompt)).count > 1)
  }

  @Test func execute_WithEmptyLabel_ThrowsEmptyLabelError() async {
    let classes = [DatasetClassSpec(label: "  ", prompt: "a cat")]

    await #expect(throws: GenerateDatasetError.emptyLabel) {
      try await sut.execute(
        classes: classes,
        styleIndex: 0,
        countPerClass: 4,
        writer: mockWriter
      ) { _, _ in }
    }
  }

  @Test func execute_WithEmptyPrompt_ThrowsEmptyPromptError() async {
    let classes = [DatasetClassSpec(label: "cat", prompt: "")]

    await #expect(throws: GenerateDatasetError.emptyPrompt) {
      try await sut.execute(
        classes: classes,
        styleIndex: 0,
        countPerClass: 4,
        writer: mockWriter
      ) { _, _ in }
    }
  }

  @Test func execute_WhenRepositoryFails_PropagatesError() async {
    mockRepository.shouldThrowError = true
    let classes = [DatasetClassSpec(label: "cat", prompt: "a cat")]

    await #expect(throws: TestError.generic) {
      try await sut.execute(
        classes: classes,
        styleIndex: 0,
        countPerClass: 4,
        writer: mockWriter
      ) { _, _ in }
    }
  }

  @Test func execute_WhenRepositoryReturnsNoImages_StopsWithoutInfiniteLoop() async throws {
    mockRepository.imagePerRequest = nil
    let classes = [DatasetClassSpec(label: "cat", prompt: "a cat")]

    try await sut.execute(
      classes: classes,
      styleIndex: 0,
      countPerClass: 8,
      writer: mockWriter
    ) { _, _ in }

    #expect(mockRepository.generateImagesCallCount == 1)
    #expect(mockWriter.writeCallCount == 0)
  }
}
