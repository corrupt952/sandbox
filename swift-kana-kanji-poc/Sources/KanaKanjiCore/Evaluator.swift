import Foundation

/// Scores the converter against a fixed test set.
///
/// The bar for this experiment is "roughly MS-IME", which is a feel, not a
/// number. A strict top-1 exact match is a poor proxy for feel, so top-5
/// coverage is reported next to it: it separates "the model has no idea" from
/// "the right answer is there but ranked wrong", and only the first of those is
/// a reason to abandon a cost-based engine.
public struct Evaluator {
  public struct Case {
    public var reading: String
    /// Accepted surfaces. Orthographic variants (良かった / よかった) are all
    /// legitimate, so a case may list several.
    public var accepted: [String]
    /// Surfaces that must not be produced, written `!surface`.
    ///
    /// The goal here is the feel of MS-IME, and that reputation is built on
    /// not breaking rather than on being right: it declines to be brilliant
    /// and lets the dictionary carry the rest. Under that standard
    /// けっか→けっか is not a failure — the reading came back unconverted, the
    /// user can add a word or confirm it once and have it learned. But
    /// みず→見ず is, because nothing asked for 見ず and the engine invented it.
    ///
    /// Counting both as "wrong" hides the difference and points tuning at the
    /// wrong target. A forbidden case fails only on the second kind.
    public var forbidden: [String]

    public var isNegative: Bool { accepted.isEmpty && !forbidden.isEmpty }
  }

  public struct Result {
    public var testCase: Case
    public var candidates: [String]
    public var topRank: Int?

    public var isTop1: Bool { topRank == 0 }
  }

  public struct Report {
    public var results: [Result]
    public var candidateCount: Int

    public var total: Int { results.count }
    public var top1: Int { results.filter(\.isTop1).count }
    public var covered: Int { results.filter { $0.topRank != nil }.count }
    public var top1Rate: Double { total == 0 ? 0 : Double(top1) / Double(total) }
    public var coverageRate: Double { total == 0 ? 0 : Double(covered) / Double(total) }
  }

  /// Parses `reading<TAB>expected[|alternative...]`, ignoring blanks and `#`.
  /// An expectation prefixed with `!` is forbidden rather than required.
  public static func parseTestSet(_ text: String) -> [Case] {
    text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
      let columns = trimmed.components(separatedBy: "\t").filter { !$0.isEmpty }
      guard columns.count >= 2 else { return nil }

      var accepted: [String] = []
      var forbidden: [String] = []
      for item in columns[1].components(separatedBy: "|") {
        let value = item.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { continue }
        if value.hasPrefix("!") {
          forbidden.append(String(value.dropFirst()))
        } else {
          accepted.append(value)
        }
      }
      guard !accepted.isEmpty || !forbidden.isEmpty else { return nil }
      return Case(reading: columns[0], accepted: accepted, forbidden: forbidden)
    }
  }

  /// Engine-agnostic: `convert` returns candidate texts, cheapest first, so the
  /// same test set scores the lattice layer and the index layer alike. The
  /// interesting number is the gap between them.
  public static func run(
    cases: [Case], candidateCount: Int, convert: (String, Int) -> [String]
  ) -> Report {
    let results = cases.map { testCase -> Result in
      let candidates = convert(testCase.reading, candidateCount)
      // A negative case fails only when the garbage is what you get — being
      // somewhere down the list is what a candidate list is for. Treating a
      // pass as rank 0 lets both kinds share one scoreboard.
      //
      // Matching is by substring, not equality. Forbidding whole strings only
      // catches the exact breakage already seen: 「教派暑かった」 was listed,
      // the engine later produced 「教派扱った」, and the test passed. A
      // forbidden fragment catches both, and every other sentence 教派 leaks
      // into.
      let rank: Int?
      if testCase.isNegative {
        let top = candidates.first ?? ""
        rank = testCase.forbidden.contains(where: { top.contains($0) }) ? nil : 0
      } else {
        rank = candidates.firstIndex { testCase.accepted.contains($0) }
      }
      return Result(testCase: testCase, candidates: candidates, topRank: rank)
    }
    return Report(results: results, candidateCount: candidateCount)
  }
}
