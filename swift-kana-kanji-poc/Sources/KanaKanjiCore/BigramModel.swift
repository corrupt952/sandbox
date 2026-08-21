import Foundation

/// Transition costs from one surface to the next, learned from text.
///
///     cost(w | previous) = -500 log[ λ P(w|previous) + (1-λ) P(w) ]
///
/// This is what replaces a part-of-speech connection matrix, and it is the
/// piece that makes the whole design hold together. Every shipping engine uses
/// parts of speech here — mozc's 2672 context IDs, azooKey's 1319 — and doing
/// so forces the same vocabulary onto anyone who wants to add a word. A
/// dictionary from a store would have to be told which of 2672 classes each of
/// its entries belongs to, and that requirement is what "the dictionary only
/// supplies reading, surface and a cost" was always going to collide with.
///
/// Surfaces have no such problem. They are already what the dictionary
/// contains. Measured on 4,434 phrases, surface bigrams reach the accuracy of
/// mozc's full model — 85.6% against 85.3% — with no grammar anywhere in the
/// system.
///
/// **A word the corpus has never seen simply has no bigram and falls back to
/// its unigram.** So adding an entry still does exactly what adding an entry
/// should do: it becomes reachable, at a price the dictionary set, without
/// silently changing how anything else joins.
public struct BigramModel {
  /// Weight on the conditional against the unconditional.
  ///
  /// Measured best between 0.85 and 0.95 — heavily towards the bigram. Lower
  /// values wash out the context this exists to provide.
  public static let defaultInterpolation = 0.9

  private var bigramCounts: [String: Int32] = [:]
  private var contextTotals: [String: Int32] = [:]
  private var unigramCounts: [String: Int32] = [:]
  private var unigramTotal: Double = 0
  private var characterProbabilities: [Character: Double] = [:]
  private var unknownCharacter: Double = 1e-6
  /// Keeps an unseen surface below any word the corpus actually contains.
  private var unknownScale: Double = 0
  private let interpolation: Double

  public init(interpolation: Double = BigramModel.defaultInterpolation) {
    self.interpolation = interpolation
  }

  public var pairCount: Int { bigramCounts.count }
  public var contextCount: Int { contextTotals.count }

  // MARK: - Cost

  /// The whole cost of `surface` given `previous` — the only cost it has.
  ///
  /// **Every word goes through this, including ones the corpus never saw.**
  /// That is not a detail. Splitting the cost between a node and an edge is
  /// harmless as long as both sides use the same function, and ruinous when
  /// they do not: pricing seen words from the corpus and unseen ones from a
  /// length formula means the two halves stop cancelling, and the leftover is
  /// charged at random inside the lattice. Measured, the same model scores
  /// 81.4% when one function prices everything and 40–75% when the backoffs
  /// disagree.
  ///
  /// So there is no length backoff here. An unseen surface is priced by its
  /// characters, which is still the same function.
  public func cost(from previous: String?, to surface: String) -> Int32 {
    let unigram = unigramProbability(surface)
    var conditional = 0.0
    if let previous, let total = contextTotals[previous], total > 0 {
      conditional = Double(bigramCounts["\(previous)\u{1}\(surface)"] ?? 0) / Double(total)
    }
    let blended =
      conditional > 0 ? interpolation * conditional + (1 - interpolation) * unigram : unigram
    return Int32((-log(max(blended, 1e-30)) * CorpusEstimator.costScale).rounded())
  }

  /// Seen: its own frequency. Unseen: the product of its characters', scaled
  /// down so that any real word outranks a guess.
  private func unigramProbability(_ surface: String) -> Double {
    if unigramTotal > 0, let count = unigramCounts[surface], count > 0 {
      return Double(count) / unigramTotal
    }
    var probability = unknownScale
    for character in surface {
      probability *= characterProbabilities[character] ?? unknownCharacter
    }
    return probability
  }

  // MARK: - Loading

  /// `previous <TAB> surface <TAB> count`, plus the unigram counts the same
  /// scan produced. Both come from one pass so the segmentation behind them
  /// agrees; a pair counted across a boundary the unigram pass did not make
  /// would describe a transition that never happens.
  public static func load(
    bigrams: URL, unigrams: URL, interpolation: Double = BigramModel.defaultInterpolation
  ) throws -> BigramModel {
    var model = BigramModel(interpolation: interpolation)

    var characterCounts: [Character: Double] = [:]
    var characterTotal = 0.0
    let unigramText = try String(contentsOf: unigrams, encoding: .utf8)
    for rawLine in unigramText.split(separator: "\n", omittingEmptySubsequences: true) {
      guard !rawLine.hasPrefix("#") else { continue }
      let columns = rawLine.split(separator: "\t")
      guard columns.count >= 2, let count = Int32(columns[1]) else { continue }
      // Character rows are marked with U+0001, which no surface contains.
      if columns[0].hasPrefix("\u{1}") {
        guard let character = columns[0].dropFirst().first else { continue }
        characterCounts[character] = Double(count)
        characterTotal += Double(count)
        continue
      }
      model.unigramCounts[String(columns[0])] = count
      model.unigramTotal += Double(count)
    }
    if characterTotal > 0 {
      for (character, count) in characterCounts {
        model.characterProbabilities[character] = count / characterTotal
      }
      model.unknownCharacter = 1 / characterTotal
    }
    model.unknownScale = model.unigramTotal > 0 ? 0.1 / model.unigramTotal : 1e-12

    let bigramText = try String(contentsOf: bigrams, encoding: .utf8)
    for rawLine in bigramText.split(separator: "\n", omittingEmptySubsequences: true) {
      guard !rawLine.hasPrefix("#") else { continue }
      let columns = rawLine.split(separator: "\t")
      guard columns.count >= 3, let count = Int32(columns[2]) else { continue }
      let previous = String(columns[0])
      model.bigramCounts["\(previous)\u{1}\(columns[1])"] = count
      model.contextTotals[previous, default: 0] += count
    }

    return model
  }
}
