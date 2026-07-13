import CoreGraphics
import Foundation
import ImageClassifierCore
import ImagePlayground

enum ImagePlaygroundRepositoryError: Error {
  case invalidStyleIndex
}

@MainActor
final class ImagePlaygroundRepository: ImageGenerationRepositoryProtocol {
  private var creator: ImageCreator?
  private var styles: [ImagePlaygroundStyle] = []

  func availableStyleNames() async throws -> [String] {
    _ = try await ensureCreator()
    return styles.map { String(describing: $0) }
  }

  func generateImages(prompt: String, styleIndex: Int, count: Int) async throws -> [CGImage] {
    let creator = try await ensureCreator()
    guard styles.indices.contains(styleIndex) else {
      throw ImagePlaygroundRepositoryError.invalidStyleIndex
    }

    var results: [CGImage] = []
    let images = creator.images(
      for: [.text(prompt)],
      style: styles[styleIndex],
      limit: count
    )
    for try await image in images {
      results.append(image.cgImage)
    }

    return results
  }

  private func ensureCreator() async throws -> ImageCreator {
    if let creator {
      return creator
    }

    let created = try await ImageCreator()
    creator = created
    styles = created.availableStyles
    return created
  }
}
