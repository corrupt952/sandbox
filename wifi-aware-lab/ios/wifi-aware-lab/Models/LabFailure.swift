import Foundation

nonisolated struct LabFailure: Equatable, Sendable {
  // MARK: - Properties

  /// The `WAError` case name, or `nil` when the error did not come from Wi-Fi Aware.
  let category: String?
  let description: String

  // MARK: - Public methods

  var text: String {
    guard let category else { return description }
    return "WAError.\(category) (\(description))"
  }
}
