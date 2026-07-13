import Foundation

public struct DatasetClassSpec: Identifiable, Sendable {
  public let id: UUID
  public var label: String
  public var prompt: String

  public init(id: UUID = UUID(), label: String, prompt: String) {
    self.id = id
    self.label = label
    self.prompt = prompt
  }
}
