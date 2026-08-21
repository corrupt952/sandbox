import Foundation

/// Re-estimates word costs from a corpus.
///
/// mozc's costs cannot be read as scalars. High-frequency words are given a
/// lexicalised context ID and have their cost flattened towards zero, with the
/// discriminating information moved into the connection matrix: です is 0 and
/// デス is 40, and 結果 exists at both 1 and 15263 depending on which ID it was
/// filed under. Comparing those numbers is a category error, and it is why
/// this engine needed a boundary penalty at all — λ was standing in for the
/// length normalisation a proper unigram gives you for free.
///
/// ## Why this counts surfaces rather than (reading, surface) pairs
///
/// The obvious design is to count the pair, since that is what the index is
/// keyed by. UD Japanese will not support it. Its `UnidicInfo` carries the
/// *lemma's* reading and the surface's *pronunciation*, and neither is what an
/// IME needs:
///
///     行っ   UnidicInfo=イク,行く,行っ,行く,イッ,…   lemma イク, pron イッ
///     は     UnidicInfo=ハ,は,は,は,ワ,…            lemma ハ,   pron ワ
///     講師   pron コーシ                            written こうし
///
/// The written kana of the inflected form is in no field. Recovering it means
/// undoing 長音 (コーシ → こうし but ホッケー stays ホッケー, which depends on
/// whether the word is 漢語 or 外来語) and special-casing は/へ/を. Every one
/// of those rules is a chance to corrupt the estimate silently.
///
/// Counting the surface alone needs none of it, and it answers the question
/// that actually matters: **how often is this written?** 結果 outranks けっか
/// because people write 結果. The cost is that homographs read differently —
/// 生 as なま and as せい — share one number. That is a real loss and a bounded
/// one.
public struct CorpusEstimator {
  public struct Stats {
    public var sentences: Int
    public var tokens: Int
    public var compounds: Int
    public var surfaces: Int
  }

  private(set) var counts: [String: Int] = [:]
  private(set) var total = 0

  public init() {}

  // MARK: - CoNLL-U

  /// Counts every short-unit token, plus each long-unit word once.
  ///
  /// Long units matter because the dictionary is full of compounds — 東京都,
  /// 攻撃する — that never appear as a short unit and would otherwise fall to
  /// the backoff cost purely for being compounds.
  /// - Parameter sentenceLimit: stop after this many sentences. Only useful
  ///   for tracing the learning curve — whether more corpus would still buy
  ///   anything is a question the corpus you already have can answer.
  public mutating func ingestCoNLLU(_ text: String, sentenceLimit: Int? = nil) -> Stats {
    var stats = Stats(sentences: 0, tokens: 0, compounds: 0, surfaces: 0)

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      if rawLine.hasPrefix("# sent_id") {
        if let limit = sentenceLimit, stats.sentences >= limit { break }
        stats.sentences += 1
      }
      guard !rawLine.isEmpty, !rawLine.hasPrefix("#") else { continue }

      let columns = rawLine.split(separator: "\t", omittingEmptySubsequences: false)
      guard columns.count >= 10 else { continue }
      // Multi-word tokens ("1-2") repeat their parts on the following lines.
      guard !columns[0].contains("-"), !columns[0].contains(".") else { continue }

      let surface = String(columns[1])
      if isCountable(surface) {
        counts[surface, default: 0] += 1
        total += 1
        stats.tokens += 1
      }

      // The long unit is repeated on every token it covers; take it at its
      // first one only.
      let misc = columns[9]
      if misc.contains("LUWBILabel=B"), let compound = unidicField(misc, at: 9),
        compound != surface, isCountable(compound)
      {
        counts[compound, default: 0] += 1
        total += 1
        stats.compounds += 1
      }
    }

    stats.surfaces = counts.count
    return stats
  }

  private func unidicField(_ misc: Substring, at index: Int) -> String? {
    for field in misc.split(separator: "|") where field.hasPrefix("UnidicInfo=") {
      let parts = field.dropFirst("UnidicInfo=".count)
        .split(separator: ",", omittingEmptySubsequences: false)
      guard parts.count > index, !parts[index].isEmpty else { return nil }
      return String(parts[index])
    }
    return nil
  }

  /// Punctuation and latin runs are never reached from kana input, so counting
  /// them only dilutes the totals.
  private func isCountable(_ surface: String) -> Bool {
    guard !surface.isEmpty else { return false }
    for scalar in surface.unicodeScalars {
      let v = scalar.value
      let kana = (0x3041...0x30FF).contains(v)
      let kanji = (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
      let iteration = v == 0x3005  // 々
      if kana || kanji || iteration { return true }
    }
    return false
  }

  // MARK: - Costs

  /// `-log(p) * 500` puts typical words in the 2000–8000 band, which is where
  /// mozc's own costs sit. Keeping the scale means λ, the neutral cost for
  /// added dictionaries and the segmentation thresholds all keep their meaning
  /// while the numbers underneath become trustworthy.
  public static let costScale = 500.0

  /// Cost for a surface the corpus never saw.
  ///
  /// Proportional to reading length, and this is the part that matters most:
  /// a flat backoff is exactly what forces a boundary penalty to exist. With a
  /// length term, covering a long reading with several unseen pieces already
  /// costs more than covering it with one, so λ has nothing left to do.
  public static func backoffCost(readingLength: Int) -> Int32 {
    Int32(2000 + 1800 * max(readingLength, 1))
  }

  /// nil when the corpus has never seen this surface, so the caller can decide
  /// what to fall back to.
  public func cost(surface: String) -> Int32? {
    guard total > 0, let count = counts[surface] else { return nil }
    return Int32((-log(Double(count) / Double(total)) * CorpusEstimator.costScale).rounded())
  }

  public var surfaceCount: Int { counts.count }
  public var tokenCount: Int { total }

  /// `surface <TAB> count`, so the estimate is inspectable and diffable
  /// between corpora.
  public func serialized() -> String {
    var lines = ["# surface\tcount\ttotal=\(total)"]
    for (surface, count) in counts.sorted(by: {
      $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
    }) {
      lines.append("\(surface)\t\(count)")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  public static func parse(_ text: String) -> CorpusEstimator {
    var estimator = CorpusEstimator()
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
      guard !rawLine.hasPrefix("#") else { continue }
      let columns = rawLine.split(separator: "\t")
      guard columns.count >= 2, let count = Int(columns[1]) else { continue }
      estimator.counts[String(columns[0])] = count
      estimator.total += count
    }
    return estimator
  }

  public static func load(contentsOf url: URL) throws -> CorpusEstimator {
    parse(try String(contentsOf: url, encoding: .utf8))
  }
}
