import Foundation

nonisolated struct LabDevice: Identifiable, Equatable, Hashable, Sendable {
  // MARK: - Nested types

  typealias ID = UInt64

  // MARK: - Properties

  let id: ID
  let name: String?
  let vendorName: String?
  let modelName: String?

  var displayName: String {
    name ?? "Device \(id)"
  }

  var detail: String {
    guard let vendorName, let modelName else { return "ID \(id)" }
    return "\(vendorName) / \(modelName) / ID \(id)"
  }
}
