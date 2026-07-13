public enum SyntheticShape: String, CaseIterable, Sendable {
  case circle
  case square
  case triangle

  public var label: String {
    rawValue
  }
}
