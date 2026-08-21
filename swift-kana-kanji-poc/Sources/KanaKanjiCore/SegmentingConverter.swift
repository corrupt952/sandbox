import Foundation

/// Segmentation with no part-of-speech anywhere.
///
///     path_cost = Σ entry_cost(w) + λ × (number of segments)
///
/// That is 文節数最小法 written as a cost. It asks the dictionary for a reading,
/// a surface and (optionally) a scalar cost — never a context ID — so a
/// third-party dictionary can join the lattice without being told what
/// part-of-speech system to speak.
///
/// The one rule that matters: **layer priority does not decide the split.**
/// A user entry that covers a long reading, given its usual absolute priority,
/// swallows the sentence — きょうは committed once as 教派 then blocks
/// きょう|は forever. So entries from the user and mode layers enter the
/// lattice at a neutral cost and win only *within* a segment, where the total
/// order still holds.
public final class SegmentingConverter {
  public struct Segment {
    public var reading: String
    /// Best surface for this segment, after layer priority is applied.
    public var surface: String
    /// Alternatives for this segment, cheapest first, layer order respected.
    public var alternatives: [LayeredIndex.Candidate]
    public var isFallback: Bool
  }

  public struct Result {
    public var text: String
    public var cost: Int32
    public var segments: [Segment]
  }

  public struct Configuration {
    /// λ. Higher means fewer, longer segments.
    ///
    /// Measured on samples/: top-1 rises 4% → 33% between λ=500 and λ=4000,
    /// then flattens. 5000 sits at the start of the plateau, which is the
    /// safer end — raising λ buys nothing further and merges more eagerly.
    public var boundaryCost: Int32
    /// Cost given to user and mode entries while segmenting, so that layer
    /// priority cannot buy a split. Roughly mid-range for mozc costs.
    public var neutralCost: Int16
    /// Longest reading a single segment may cover, in characters.
    public var maxSegmentLength: Int
    /// Lattice nodes kept per span, cheapest first.
    public var nodesPerSpan: Int

    public init(
      boundaryCost: Int32 = 5000, neutralCost: Int16 = 4000, maxSegmentLength: Int = 16,
      nodesPerSpan: Int = 8
    ) {
      self.boundaryCost = boundaryCost
      self.neutralCost = neutralCost
      self.maxSegmentLength = maxSegmentLength
      self.nodesPerSpan = nodesPerSpan
    }
  }

  private let index: LayeredIndex
  public var configuration: Configuration
  /// Transition costs learned from text. Without one, every boundary costs the
  /// same λ and the split is decided by how many segments it takes.
  public var bigrams: BigramModel?

  public init(
    index: LayeredIndex, configuration: Configuration = Configuration(),
    bigrams: BigramModel? = nil
  ) {
    self.index = index
    self.configuration = configuration
    self.bigrams = bigrams
  }

  public func convert(_ input: String, count: Int = 5) -> [Result] {
    let characters = Array(Kana.toHiragana(input))
    guard !characters.isEmpty else { return [] }

    var lattice = Lattice(inputLength: characters.count)
    // Readings are recovered from the span, so the node only has to remember
    // where it sat. leftId/rightId stay 0: nothing here uses them.
    var spanReadings: [String: [LayeredIndex.Candidate]] = [:]

    for start in 0..<characters.count {
      let limit = min(start + configuration.maxSegmentLength, characters.count)
      var anyAtStart = false
      for end in (start + 1)...limit {
        let reading = String(characters[start..<end])
        // No kana tail here: kana is a way of presenting a segment, not a
        // word that can win one. Letting it into the lattice would make every
        // span passable at zero cost and the split meaningless.
        let matches = index.candidates(
          for: reading, limit: configuration.nodesPerSpan, predictionKeys: 0, kanaTail: false)
        guard !matches.isEmpty else { continue }
        spanReadings[reading] = matches
        anyAtStart = true
        for candidate in matches {
          lattice.insert(
            LatticeNode(
              surface: candidate.surface, reading: reading, start: start, end: end, leftId: 0,
              rightId: 0,
              // With a bigram the whole cost lives on the edge, because that
              // is the only way both halves come from one function.
              wordCost: bigrams == nil ? segmentationCost(of: candidate) : 0,
              isUnknown: false))
        }
      }

      // Keep the lattice traversable through readings nothing covers.
      if !anyAtStart {
        let reading = String(characters[start..<(start + 1)])
        lattice.insert(
          LatticeNode(
            surface: reading, reading: reading, start: start, end: start + 1, leftId: 0,
            rightId: 0, wordCost: bigrams == nil ? 8000 : 0, isUnknown: true))
      }
    }

    // Ask for extra paths: several of them differ only in which dictionary row
    // supplied an identical surface, and those collapse into one candidate.
    // With a bigram, the transition is what the corpus says about this pair
    // and the flat penalty is only a floor to keep splits from being free.
    // Without one, the flat penalty is the whole model.
    let boundary = configuration.boundaryCost
    let bigrams = self.bigrams
    let paths = lattice.search(count: count * 4) { previous, node in
      guard let bigrams else { return boundary }
      let context = previous.surface.isEmpty ? nil : previous.surface
      return bigrams.cost(from: context, to: node.surface)
    }

    var results: [Result] = []
    var seen: Set<String> = []
    for path in paths {
      let segments = path.segments.map { segment -> Segment in
        let alternatives = spanReadings[segment.reading] ?? []
        return Segment(
          reading: segment.reading,
          surface: alternatives.first?.surface ?? segment.surface,
          alternatives: alternatives,
          isFallback: segment.isUnknown)
      }
      let text = segments.map(\.surface).joined()
      guard !seen.contains(text) else { continue }
      seen.insert(text)
      results.append(Result(text: text, cost: path.cost, segments: segments))
      if results.count == count { break }
    }
    return results
  }

  /// Baseline entries keep their own cost; everything above it is flattened.
  private func segmentationCost(of candidate: LayeredIndex.Candidate) -> Int32 {
    candidate.priority == .baseline ? Int32(candidate.cost) : Int32(configuration.neutralCost)
  }
}
