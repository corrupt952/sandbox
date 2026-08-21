import Foundation

/// Kana -> kanji conversion: build a lattice from the compiled lexicon, then
/// pick the cheapest paths through it.
public final class Converter {
  private let lexicon: Lexicon
  private let matrix: ConnectionMatrix
  private let charProperty: SourceParsing.CharProperty
  private let unknownTemplates: [String: [SourceParsing.UnknownTemplate]]
  private let maxKeyByteLength: Int

  public init(dataDirectory: URL) throws {
    lexicon = try Lexicon(contentsOf: dataDirectory.appendingPathComponent("lexicon.bin"))
    matrix = try ConnectionMatrix(contentsOf: dataDirectory.appendingPathComponent("matrix.bin"))

    let charDefURL = dataDirectory.appendingPathComponent("char.def")
    let unkDefURL = dataDirectory.appendingPathComponent("unk.def")
    guard FileManager.default.fileExists(atPath: charDefURL.path) else {
      throw FormatError.missingResource(charDefURL.path)
    }
    guard FileManager.default.fileExists(atPath: unkDefURL.path) else {
      throw FormatError.missingResource(unkDefURL.path)
    }
    charProperty = try SourceParsing.parseCharDef(
      String(contentsOf: charDefURL, encoding: .utf8))
    unknownTemplates = try SourceParsing.parseUnkDef(
      String(contentsOf: unkDefURL, encoding: .utf8))
    maxKeyByteLength = lexicon.maxKeyByteLength
  }

  public var lexiconEntryCount: Int { lexicon.numberOfEntries }
  public var lexiconKeyCount: Int { lexicon.numberOfKeys }
  public var contextSize: (left: Int, right: Int) { (matrix.leftSize, matrix.rightSize) }

  /// Converts one reading. Returns up to `count` candidates, cheapest first.
  public func convert(_ input: String, count: Int = 10) -> [Candidate] {
    let original = Array(input)
    guard !original.isEmpty else { return [] }
    // Lookups are keyed in hiragana; katakana typed directly still matches.
    let normalized = original.map { Character(Kana.toHiragana(String($0))) }

    var lattice = Lattice(inputLength: original.count)
    var hasLexiconMatch = Array(repeating: false, count: original.count)

    for start in 0..<original.count {
      var end = start + 1
      while end <= original.count {
        let key = Array(String(normalized[start..<end]).utf8)
        if key.count > maxKeyByteLength { break }
        for entry in lexicon.entries(forKey: key) {
          hasLexiconMatch[start] = true
          lattice.insert(
            LatticeNode(
              surface: entry.surface, reading: String(normalized[start..<end]), start: start,
              end: end, leftId: entry.leftId, rightId: entry.rightId, wordCost: Int32(entry.cost),
              isUnknown: false))
        }
        end += 1
      }
    }

    insertUnknownNodes(
      into: &lattice, original: original, normalized: normalized,
      hasLexiconMatch: hasLexiconMatch)

    if !lattice.isConnected {
      // Last resort: a single-character node at every position keeps the
      // lattice traversable so the user always gets something back.
      for start in 0..<original.count {
        insertUnknown(
          into: &lattice, category: charProperty.defaultCategory, original: original,
          normalized: normalized, start: start, end: start + 1)
      }
    }

    return lattice.search(matrix: matrix, count: count)
  }

  private func insertUnknownNodes(
    into lattice: inout Lattice, original: [Character], normalized: [Character],
    hasLexiconMatch: [Bool]
  ) {
    for start in 0..<original.count {
      guard let scalar = original[start].unicodeScalars.first else { continue }
      let category = charProperty.category(of: scalar)
      guard category.invoke || !hasLexiconMatch[start] else { continue }

      // How far the run of same-category characters extends.
      var runEnd = start + 1
      while runEnd < original.count,
        let next = original[runEnd].unicodeScalars.first,
        charProperty.category(of: next).name == category.name
      {
        runEnd += 1
      }

      var lengths: Set<Int> = []
      if category.group { lengths.insert(runEnd - start) }
      if category.length > 0 {
        for length in 1...category.length where start + length <= runEnd {
          lengths.insert(length)
        }
      }
      if lengths.isEmpty { lengths.insert(1) }

      for length in lengths.sorted() {
        insertUnknown(
          into: &lattice, category: category.name, original: original, normalized: normalized,
          start: start, end: start + length)
      }
    }
  }

  private func insertUnknown(
    into lattice: inout Lattice, category: String, original: [Character],
    normalized: [Character], start: Int, end: Int
  ) {
    let templates = unknownTemplates[category] ?? unknownTemplates["DEFAULT"] ?? []
    let surface = String(original[start..<end])
    let reading = String(normalized[start..<end])
    for template in templates {
      lattice.insert(
        LatticeNode(
          surface: surface, reading: reading, start: start, end: end, leftId: template.leftId,
          rightId: template.rightId, wordCost: Int32(template.cost), isUnknown: true))
    }
  }
}
