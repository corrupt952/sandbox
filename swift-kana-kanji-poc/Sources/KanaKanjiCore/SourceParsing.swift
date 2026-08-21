import Foundation

/// Parsers for the mecab-ipadic source files.
enum SourceParsing {
  /// Splits one ipadic CSV row. ipadic quotes fields that contain a comma
  /// (the lexical entry for "," itself, for example), with `""` as the escape.
  static func splitCSV(_ line: some StringProtocol) -> [String] {
    var fields: [String] = []
    var current = ""
    var inQuotes = false
    var index = line.startIndex
    while index < line.endIndex {
      let ch = line[index]
      if inQuotes {
        if ch == "\"" {
          let next = line.index(after: index)
          if next < line.endIndex, line[next] == "\"" {
            current.append("\"")
            index = next
          } else {
            inQuotes = false
          }
        } else {
          current.append(ch)
        }
      } else if ch == "\"", current.isEmpty {
        inQuotes = true
      } else if ch == "," {
        fields.append(current)
        current = ""
      } else {
        current.append(ch)
      }
      index = line.index(after: index)
    }
    fields.append(current)
    return fields
  }

  /// One character category from char.def.
  struct CharCategory {
    var name: String
    /// Run unknown-word generation even when the lexicon already matched here.
    var invoke: Bool
    /// Emit one node covering the whole run of same-category characters.
    var group: Bool
    /// Also emit nodes of length 1...length.
    var length: Int
  }

  struct CharProperty {
    var categories: [String: CharCategory]
    /// Scalar ranges mapped to their primary category name.
    private var ranges: [(lower: UInt32, upper: UInt32, category: String)]
    var defaultCategory: String

    init(categories: [String: CharCategory], ranges: [(UInt32, UInt32, String)]) {
      self.categories = categories
      self.ranges = ranges.map { (lower: $0.0, upper: $0.1, category: $0.2) }
      self.defaultCategory = "DEFAULT"
    }

    func category(of scalar: Unicode.Scalar) -> CharCategory {
      for range in ranges where scalar.value >= range.lower && scalar.value <= range.upper {
        if let category = categories[range.category] { return category }
      }
      return categories[defaultCategory]
        ?? CharCategory(name: defaultCategory, invoke: true, group: true, length: 0)
    }
  }

  /// char.def has two kinds of lines: category definitions
  /// (`NAME INVOKE GROUP LENGTH`) and code point ranges
  /// (`0x3041..0x309F HIRAGANA [compatible categories...]`).
  static func parseCharDef(_ text: String) throws -> CharProperty {
    var categories: [String: CharCategory] = [:]
    var ranges: [(UInt32, UInt32, String)] = []

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
      let line = stripComment(rawLine)
      guard !line.isEmpty else { continue }
      let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
      guard tokens.count >= 2 else { continue }

      if tokens[0].hasPrefix("0x") {
        guard let (lower, upper) = parseRange(tokens[0]) else { continue }
        ranges.append((lower, upper, tokens[1]))
      } else if tokens.count >= 4, let invoke = Int(tokens[1]), let group = Int(tokens[2]),
        let length = Int(tokens[3])
      {
        categories[tokens[0]] = CharCategory(
          name: tokens[0], invoke: invoke != 0, group: group != 0, length: length)
      }
    }

    guard !categories.isEmpty else {
      throw FormatError.malformedSource("char.def has no categories")
    }
    return CharProperty(categories: categories, ranges: ranges)
  }

  private static func parseRange(_ token: String) -> (UInt32, UInt32)? {
    let parts = token.components(separatedBy: "..")
    guard let lower = parseHex(parts[0]) else { return nil }
    if parts.count == 1 { return (lower, lower) }
    guard let upper = parseHex(parts[1]) else { return nil }
    return (lower, upper)
  }

  private static func parseHex(_ token: String) -> UInt32? {
    guard token.hasPrefix("0x") else { return nil }
    return UInt32(token.dropFirst(2), radix: 16)
  }

  private static func stripComment(_ line: some StringProtocol) -> String {
    if let hash = line.firstIndex(of: "#") {
      return String(line[line.startIndex..<hash]).trimmingCharacters(in: .whitespaces)
    }
    return String(line).trimmingCharacters(in: .whitespaces)
  }

  /// An unknown-word template: unk.def rows keyed by category name.
  struct UnknownTemplate {
    var leftId: UInt16
    var rightId: UInt16
    var cost: Int16
  }

  static func parseUnkDef(_ text: String) -> [String: [UnknownTemplate]] {
    var result: [String: [UnknownTemplate]] = [:]
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
      let fields = splitCSV(rawLine)
      guard fields.count >= 4,
        let leftId = UInt16(fields[1]), let rightId = UInt16(fields[2]), let cost = Int32(fields[3])
      else { continue }
      let template = UnknownTemplate(
        leftId: leftId, rightId: rightId, cost: Int16(clamping: cost))
      result[fields[0], default: []].append(template)
    }
    return result
  }
}
