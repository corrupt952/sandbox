import Foundation

/// A small in-memory dictionary loaded from text.
///
/// This is the format users and the dictionary store actually exchange: the
/// MS-IME user dictionary export, `reading <TAB> surface <TAB> part-of-speech`.
/// The index layer only needs the first two columns, so the part-of-speech is
/// read but not used yet -- it becomes meaningful when the lattice layer comes
/// back.
public struct TextDictionary {
  public struct Entry {
    public var surface: String
    public var partOfSpeech: String
  }

  /// Readings in sorted order, for prefix search.
  private var sortedReadings: [String]
  private var table: [String: [Entry]]

  public init(entries: [(reading: String, surface: String, partOfSpeech: String)]) {
    var table: [String: [Entry]] = [:]
    for entry in entries {
      let reading = Kana.toHiragana(entry.reading)
      guard !reading.isEmpty, !entry.surface.isEmpty else { continue }
      table[reading, default: []].append(
        Entry(surface: entry.surface, partOfSpeech: entry.partOfSpeech))
    }
    self.table = table
    self.sortedReadings = table.keys.sorted { compareBytes(Array($0.utf8), Array($1.utf8)) < 0 }
  }

  public var readingCount: Int { sortedReadings.count }
  public var entryCount: Int { table.values.reduce(0) { $0 + $1.count } }

  public func entries(forReading reading: String) -> [Entry] {
    table[reading] ?? []
  }

  public func entries(withPrefix prefix: String, maxKeys: Int) -> [(String, [Entry])] {
    guard !prefix.isEmpty, maxKeys > 0 else { return [] }
    var results: [(String, [Entry])] = []
    var index = lowerBound(prefix)
    while index < sortedReadings.count, results.count < maxKeys {
      let reading = sortedReadings[index]
      guard reading.hasPrefix(prefix) else { break }
      results.append((reading, table[reading] ?? []))
      index += 1
    }
    return results
  }

  private func lowerBound(_ prefix: String) -> Int {
    let target = Array(prefix.utf8)
    var low = 0
    var high = sortedReadings.count
    while low < high {
      let mid = (low + high) / 2
      if compareBytes(Array(sortedReadings[mid].utf8), target) < 0 {
        low = mid + 1
      } else {
        high = mid
      }
    }
    return low
  }

  // MARK: - Parsing

  /// Parses the MS-IME user dictionary export format.
  ///
  /// Columns are tab-separated in practice despite the ".csv" naming, so both
  /// separators are accepted. Lines starting with `!` or `;` are comments --
  /// the exporter writes a `!Microsoft IME Dictionary Tool` banner.
  public static func parse(_ text: String) -> TextDictionary {
    var entries: [(reading: String, surface: String, partOfSpeech: String)] = []
    for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix(";"), !line.hasPrefix("#") else {
        continue
      }
      let columns =
        line.contains("\t")
        ? line.components(separatedBy: "\t")
        : SourceParsing.splitCSV(line)
      guard columns.count >= 2 else { continue }
      let reading = columns[0].trimmingCharacters(in: .whitespaces)
      let surface = columns[1].trimmingCharacters(in: .whitespaces)
      guard !reading.isEmpty, !surface.isEmpty else { continue }
      let pos = columns.count >= 3 ? columns[2].trimmingCharacters(in: .whitespaces) : "名詞"
      entries.append((reading: reading, surface: surface, partOfSpeech: pos))
    }
    return TextDictionary(entries: entries)
  }

  public static func load(contentsOf url: URL) throws -> TextDictionary {
    parse(try String(contentsOf: url, encoding: .utf8))
  }

  /// Serialises back to the same format, so a session's additions survive.
  public func serialized() -> String {
    var lines: [String] = ["!Microsoft IME Dictionary Tool"]
    for reading in sortedReadings {
      for entry in table[reading] ?? [] {
        lines.append("\(reading)\t\(entry.surface)\t\(entry.partOfSpeech)")
      }
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// Removes one entry.
  ///
  /// A total order over layers guarantees that anything learned here is the
  /// first candidate, forever. That is the feature, and undoing it is the
  /// price: a single mistaken commit pins the wrong word until it is taken
  /// back. MS-IME carries the same debt and pays it with 「学習情報の消去」.
  @discardableResult
  public mutating func remove(reading: String, surface: String) -> Bool {
    let key = Kana.toHiragana(reading)
    guard var entries = table[key] else { return false }
    let before = entries.count
    entries.removeAll { $0.surface == surface }
    guard entries.count != before else { return false }
    if entries.isEmpty {
      table[key] = nil
      if let position = sortedReadings.firstIndex(of: key) {
        sortedReadings.remove(at: position)
      }
    } else {
      table[key] = entries
    }
    return true
  }

  public mutating func removeAll() {
    table = [:]
    sortedReadings = []
  }

  public mutating func add(reading: String, surface: String, partOfSpeech: String = "名詞") {
    let key = Kana.toHiragana(reading)
    guard !key.isEmpty, !surface.isEmpty else { return }
    var entries = table[key] ?? []
    guard !entries.contains(where: { $0.surface == surface }) else { return }
    // Newest first: the last thing the user taught it should win.
    entries.insert(Entry(surface: surface, partOfSpeech: partOfSpeech), at: 0)
    table[key] = entries
    if entries.count == 1 {
      let position = lowerBound(key)
      sortedReadings.insert(key, at: position)
    }
  }
}
