import Foundation

/// The index layer: reading -> word candidates, with no lattice and no Viterbi.
///
/// Three dictionaries stack, and conflicts are resolved by a **total order on
/// layers**, not by cost:
///
///     user     > mode > baseline
///
/// That ordering is the point. A cost-based engine cannot promise that adding
/// a word makes it win -- enough accumulated cost elsewhere can still beat it.
/// A total order can: anything in the user dictionary is always the first
/// candidate, without exception. When the product promise is "install this
/// dictionary and this word converts", the weaker mechanism is the one that
/// keeps the promise.
public final class LayeredIndex {
  public enum Priority: Int, Comparable, CaseIterable {
    /// Written down on purpose. Never decays.
    case user = 0
    /// Picked up from what the user actually typed. Decays.
    case learned = 1
    /// Installed for a domain.
    case mode = 2
    case baseline = 3

    public static func < (lhs: Priority, rhs: Priority) -> Bool {
      lhs.rawValue < rhs.rawValue
    }

    public var label: String {
      switch self {
      case .user: return "user"
      case .learned: return "learned"
      case .mode: return "mode"
      case .baseline: return "baseline"
      }
    }
  }

  public struct Candidate: Identifiable {
    public var id: String { "\(reading)\u{1}\(surface)" }
    public var surface: String
    public var reading: String
    public var priority: Priority
    public var layerName: String
    /// Within-layer ordering only. Never compared across layers.
    public var cost: Int16
    /// True when the reading matches exactly what was typed, false when the
    /// candidate came from a longer reading (prediction).
    public var isExact: Bool

    public init(
      surface: String, reading: String, priority: Priority, layerName: String, cost: Int16,
      isExact: Bool
    ) {
      self.surface = surface
      self.reading = reading
      self.priority = priority
      self.layerName = layerName
      self.cost = cost
      self.isExact = isExact
    }
  }

  private struct Layer {
    var name: String
    var priority: Priority
    var lexicon: Lexicon?
    var text: TextDictionary?
    var learning: LearningStore?
  }

  private var layers: [Layer] = []

  public init() {}

  public func addCompiled(_ lexicon: Lexicon, name: String, priority: Priority) {
    layers.append(Layer(name: name, priority: priority, lexicon: lexicon))
    layers.sort { $0.priority < $1.priority }
  }

  public func addText(_ dictionary: TextDictionary, name: String, priority: Priority) {
    layers.append(Layer(name: name, priority: priority, text: dictionary))
    layers.sort { $0.priority < $1.priority }
  }

  public func addLearning(_ store: LearningStore, name: String) {
    layers.append(Layer(name: name, priority: .learned, learning: store))
    layers.sort { $0.priority < $1.priority }
  }

  public func replaceText(_ dictionary: TextDictionary, name: String) {
    guard let index = layers.firstIndex(where: { $0.name == name }) else { return }
    layers[index].text = dictionary
  }

  public func replaceLearning(_ store: LearningStore, name: String) {
    guard let index = layers.firstIndex(where: { $0.name == name }) else { return }
    layers[index].learning = store
  }

  public var layerSummary: [(name: String, priority: Priority, readings: Int)] {
    layers.map { layer in
      (
        layer.name, layer.priority,
        layer.lexicon?.numberOfKeys ?? layer.text?.readingCount ?? layer.learning?.readingCount ?? 0
      )
    }
  }

  /// Candidates for a reading. Exact matches first, then predictions from
  /// longer readings; within each group, higher-priority layers win.
  ///
  /// - Parameter predictionKeys: how many distinct longer readings to pull per
  ///   layer. 0 disables prediction, giving conversion-only behaviour.
  /// - Parameter kanaTail: append the reading as hiragana and katakana at the
  ///   end. These are not dictionary entries — they are derived from the
  ///   reading — so they always exist and never compete for rank. Off for the
  ///   segmenter, which must not treat them as lattice nodes.
  public func candidates(
    for reading: String, limit: Int = 20, predictionKeys: Int = 8, kanaTail: Bool = true
  ) -> [Candidate] {
    let normalized = Kana.toHiragana(reading)
    guard !normalized.isEmpty else { return [] }
    let key = Array(normalized.utf8)

    var results: [Candidate] = []
    var seen: Set<String> = []

    func append(
      surface: String, reading: String, cost: Int16, layer: Layer, isExact: Bool
    ) {
      let identity = "\(reading)\u{1}\(surface)"
      guard !seen.contains(identity) else { return }
      seen.insert(identity)
      results.append(
        Candidate(
          surface: surface, reading: reading, priority: layer.priority, layerName: layer.name,
          cost: cost, isExact: isExact))
    }

    // Exact matches, highest-priority layer first.
    for layer in layers {
      if let lexicon = layer.lexicon {
        for entry in lexicon.entries(forKey: key) {
          append(
            surface: entry.surface, reading: normalized, cost: entry.cost, layer: layer,
            isExact: true)
        }
      }
      if let text = layer.text {
        for (offset, entry) in text.entries(forReading: normalized).enumerated() {
          append(
            surface: entry.surface, reading: normalized, cost: Int16(clamping: offset),
            layer: layer, isExact: true)
        }
      }
      if let learning = layer.learning {
        // More uses ranks better, so the cost runs the other way.
        for entry in learning.entries(forReading: normalized) {
          append(
            surface: entry.surface, reading: normalized,
            cost: Int16(Int(UInt8.max) - Int(entry.count)), layer: layer, isExact: true)
        }
      }
    }
    sortInPlace(&results)

    if predictionKeys > 0 { appendPredictions(&results, &seen, key, normalized, predictionKeys) }

    if kanaTail { appendKanaTail(to: &results, reading: normalized, seen: &seen) }
    return Array(results.prefix(limit))
  }

  /// Predictions from what this user has actually written — never from the
  /// baseline dictionary.
  ///
  /// Predicting out of a million-entry lexicon sounds free and is not.
  /// Measured on 4,434 phrases: ranking the baseline by its own costs puts a
  /// useful guess in the window 11.9% of the time and saves 0.19 kana, while
  /// never producing anything at all for 80% of phrases. The same measurement
  /// on user history gives 39.5% and 0.80 kana. What the lexicon reliably does
  /// is fill the window with のんで→ノンデイト and ですか→デス書き込み.
  ///
  /// So prediction is a property of the layers that know this user, and the
  /// baseline stays out of it.
  private func appendPredictions(
    _ results: inout [Candidate], _ seen: inout Set<String>, _ key: [UInt8], _ normalized: String,
    _ predictionKeys: Int
  ) {
    var predictions: [Candidate] = []
    for layer in layers where layer.priority != .baseline {
      if let lexicon = layer.lexicon {
        for (longer, entries) in lexicon.entries(withPrefix: key, maxKeys: predictionKeys)
        where longer != normalized {
          for entry in entries {
            let identity = "\(longer)\u{1}\(entry.surface)"
            guard !seen.contains(identity) else { continue }
            seen.insert(identity)
            predictions.append(
              Candidate(
                surface: entry.surface, reading: longer, priority: layer.priority,
                layerName: layer.name, cost: entry.cost, isExact: false))
          }
        }
      }
      if let text = layer.text {
        for (longer, entries) in text.entries(withPrefix: normalized, maxKeys: predictionKeys)
        where longer != normalized {
          for (offset, entry) in entries.enumerated() {
            let identity = "\(longer)\u{1}\(entry.surface)"
            guard !seen.contains(identity) else { continue }
            seen.insert(identity)
            predictions.append(
              Candidate(
                surface: entry.surface, reading: longer, priority: layer.priority,
                layerName: layer.name, cost: Int16(clamping: offset), isExact: false))
          }
        }
      }
      if let learning = layer.learning {
        for (longer, entries) in learning.entries(withPrefix: normalized, maxKeys: predictionKeys)
        where longer != normalized {
          for entry in entries {
            let identity = "\(longer)\u{1}\(entry.surface)"
            guard !seen.contains(identity) else { continue }
            seen.insert(identity)
            predictions.append(
              Candidate(
                surface: entry.surface, reading: longer, priority: layer.priority,
                layerName: layer.name, cost: Int16(Int(UInt8.max) - Int(entry.count)),
                isExact: false))
          }
        }
      }
    }
    sortInPlace(&predictions)
    // Merged by score rather than given reserved slots. Measured on the same
    // set: interleaving costs the true candidate 1.3pt of visibility in a
    // 5-slot window, while pinning the bottom two slots to predictions costs
    // 4.8pt — and 14.3pt in a 3-slot window.
    results += predictions
  }

  /// Hiragana and katakana of what was typed, always last.
  ///
  /// Every IME offers these and none of them make you win a ranking contest to
  /// get one. Keeping them out of the dictionary and appending them here means
  /// 結果 no longer loses to けっか, and a candidate list is never empty.
  private func appendKanaTail(
    to candidates: inout [Candidate], reading: String, seen: inout Set<String>
  ) {
    for surface in [reading, Kana.toKatakana(reading)] {
      let identity = "\(reading)\u{1}\(surface)"
      guard !seen.contains(identity) else { continue }
      seen.insert(identity)
      candidates.append(
        Candidate(
          surface: surface, reading: reading, priority: .baseline, layerName: "kana", cost: 0,
          isExact: true))
    }
  }

  private func sortInPlace(_ candidates: inout [Candidate]) {
    candidates.sort { lhs, rhs in
      if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
      if lhs.reading.count != rhs.reading.count { return lhs.reading.count < rhs.reading.count }
      if lhs.cost != rhs.cost { return lhs.cost < rhs.cost }
      return lhs.surface < rhs.surface
    }
  }
}
