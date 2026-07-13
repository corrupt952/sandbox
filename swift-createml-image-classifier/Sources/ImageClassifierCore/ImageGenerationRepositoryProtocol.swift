import CoreGraphics

@MainActor
public protocol ImageGenerationRepositoryProtocol {
  func availableStyleNames() async throws -> [String]
  func generateImages(prompt: String, styleIndex: Int, count: Int) async throws -> [CGImage]
}
