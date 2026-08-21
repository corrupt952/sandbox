import Foundation

/// Counts dictionary surfaces in plain text.
///
/// Annotated corpora come pre-tokenised; raw text does not, and Japanese has
/// no spaces. Something has to decide where one word ends.
///
/// This uses the dictionary itself: longest match, left to right, over the
/// surfaces the index already knows. That is circular in a way worth naming —
/// the counts inherit whatever the dictionary believes about wordhood, so a
/// compound it holds as one entry is counted once rather than as its parts.
/// For estimating *those same entries' costs* the circularity is harmless and
/// arguably right: the question being asked is how often this entry's surface
/// appears, and the entry is what defines the span.
///
/// It would be wrong for building a dictionary from scratch. It is not doing
/// that.
public struct SurfaceScanner {
  /// Candidates grouped by their first two characters.
  ///
  /// Grouping by one character is not enough at this scale: 「の」 starts tens
  /// of thousands of entries, and testing all of them at every 「の」 in two
  /// hundred million characters does not finish. Two characters cuts the
  /// fan-out to something small. Single-character surfaces are kept apart
  /// because they have no second character to group by.
  private var byPrefix: [String: [[Character]]] = [:]
  private var singles: Set<Character> = []
  private let maximumLength: Int

  public init(surfaces: some Sequence<String>, maximumLength: Int = 16) {
    self.maximumLength = maximumLength
    for surface in surfaces {
      let characters = Array(surface)
      guard !characters.isEmpty, characters.count <= maximumLength else { continue }
      if characters.count == 1 {
        singles.insert(characters[0])
        continue
      }
      byPrefix[String(characters[0...1]), default: []].append(characters)
    }
    // Longest first, so the scan takes the first hit and moves on.
    for key in byPrefix.keys {
      byPrefix[key]?.sort { $0.count > $1.count }
    }
  }

  public struct Counts {
    public var unigrams: [String: Int] = [:]
    public var bigrams: [String: Int] = [:]
    /// Character frequencies, for pricing surfaces the corpus never saw.
    ///
    /// A length-proportional constant will not do here. The bigram cost has to
    /// come out of one function for every word, including unseen ones, or the
    /// node and the edge stop cancelling and the difference is charged at
    /// random. Measured, getting this wrong costs 7 to 41 points.
    public var characters: [Character: Int] = [:]
    public var tokens = 0
    public var unmatched = 0

    public init() {}
  }

  /// Scans one line, counting surfaces and adjacent pairs.
  ///
  /// Pairs are what the lattice needs and what a part-of-speech matrix is
  /// standing in for: measured elsewhere, surface bigrams alone reach the
  /// accuracy of mozc's full model at phrase level. They are counted here
  /// rather than separately because the segmentation has to be the same for
  /// both — a pair counted across a boundary the unigram pass did not make
  /// would describe a transition that never happens.
  /// Counts an already-tokenised line, one unit per space-separated field.
  ///
  /// Longest match over dictionary surfaces looked reasonable and is not: it
  /// greedily takes long compounds, so the pairs it records are not the pairs
  /// the lattice proposes. Measured, it covers 55% of the adjacent pairs
  /// actually needed against 80% for morphological short units — more bigrams,
  /// the wrong ones, and table capacity spent on contexts that never arise.
  public func scanTokenised(_ line: some StringProtocol, into counts: inout Counts) {
    var previous: String?
    for field in line.split(separator: " ", omittingEmptySubsequences: true) {
      let token = String(field)
      guard isCountable(token) else {
        // Punctuation and latin runs break the chain rather than joining
        // across it: whatever followed did not follow the previous word.
        previous = nil
        counts.unmatched += 1
        continue
      }
      counts.unigrams[token, default: 0] += 1
      for character in token { counts.characters[character, default: 0] += 1 }
      counts.tokens += 1
      if let previous {
        counts.bigrams["\(previous)\u{1}\(token)", default: 0] += 1
      }
      previous = token
    }
  }

  private func isCountable(_ token: String) -> Bool {
    for scalar in token.unicodeScalars {
      let v = scalar.value
      if (0x3041...0x30FF).contains(v) || (0x4E00...0x9FFF).contains(v) || v == 0x3005 {
        return true
      }
    }
    return false
  }

  public func scan(_ line: some StringProtocol, into counts: inout Counts) {
    let characters = Array(line)
    var index = 0
    var previous: String?

    while index < characters.count {
      guard let match = longestMatch(characters, from: index) else {
        // Anything the dictionary does not cover breaks the chain: the next
        // word did not follow the previous one, something else did.
        previous = nil
        counts.unmatched += 1
        index += 1
        continue
      }
      counts.unigrams[match, default: 0] += 1
      for character in match { counts.characters[character, default: 0] += 1 }
      counts.tokens += 1
      if let previous {
        counts.bigrams["\(previous)\u{1}\(match)", default: 0] += 1
      }
      previous = match
      index += match.count
    }
  }

  private func longestMatch(_ characters: [Character], from start: Int) -> String? {
    let remaining = characters.count - start
    if remaining >= 2 {
      let prefix = String(characters[start...(start + 1)])
      if let candidates = byPrefix[prefix] {
        for candidate in candidates where candidate.count <= remaining {
          if matches(candidate, characters, at: start) { return String(candidate) }
        }
      }
    }
    return singles.contains(characters[start]) ? String(characters[start]) : nil
  }

  private func matches(_ candidate: [Character], _ characters: [Character], at start: Int) -> Bool {
    // The first two are known to match from the grouping.
    var offset = start + 2
    var index = 2
    while index < candidate.count {
      if characters[offset] != candidate[index] { return false }
      offset += 1
      index += 1
    }
    return true
  }
}
