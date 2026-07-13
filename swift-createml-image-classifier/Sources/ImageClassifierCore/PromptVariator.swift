/// ImageCreator has no seed or variation API: the same prompt and style
/// deterministically produce the same image. Appending random modifiers to
/// each request is the only way to get a varied dataset.
public struct PromptVariator: Sendable {
  private let viewpoints: [String]
  private let settings: [String]
  private let lighting: [String]

  public init(
    viewpoints: [String] = [
      "close-up view",
      "seen from the side",
      "seen from above",
      "wide shot",
      "seen from a low angle",
      "centered composition",
    ],
    settings: [String] = [
      "on a plain background",
      "outdoors in a park",
      "in a cozy room",
      "on a city street",
      "in a meadow",
      "near a window",
    ],
    lighting: [String] = [
      "bright daylight",
      "soft warm light",
      "golden hour light",
      "cool morning light",
    ]
  ) {
    self.viewpoints = viewpoints
    self.settings = settings
    self.lighting = lighting
  }

  public func variation(
    of prompt: String,
    using generator: inout any RandomNumberGenerator
  ) -> String {
    let modifiers = [
      viewpoints.randomElement(using: &generator),
      settings.randomElement(using: &generator),
      lighting.randomElement(using: &generator),
    ].compactMap { $0 }

    return ([prompt] + modifiers).joined(separator: ", ")
  }
}
