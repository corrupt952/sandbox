import Foundation

nonisolated struct LabEnvironment: Equatable, Sendable {
  // MARK: - Properties

  let serviceName: String
  let isServiceDeclared: Bool
  let capabilities: LabCapabilities
}
