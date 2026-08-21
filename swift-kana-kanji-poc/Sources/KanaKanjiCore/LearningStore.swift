import Foundation

/// What the user's own typing has taught the converter, kept apart from what
/// the user deliberately wrote down.
///
/// Learning used to go straight into the user dictionary. With a total order
/// over layers that made every mistake permanent: きょうは confirmed once as
/// 教派 sat at the top of the list forever. Every shipping IME guards against
/// this somehow — Anthy caps each learning kind at 100–1000 entries, Mozc
/// refuses to generalise a correction across differing parts of speech,
/// Chinese IMEs decline to add to the vocabulary at all — and azooKey's answer
/// is the one that survives having no parts of speech to check:
///
/// **a use count that halves every 32 days.**
///
/// A word confirmed once lasts one month and then is gone — 1 >> 1 is 0. Eight
/// confirmations last three. Nothing has to be pruned by hand, and nothing
/// becomes permanent by accident: permanence is what the user dictionary is
/// for, and it does not decay.
public struct LearningStore {
  /// Days between halvings.
  public static let halfLifeDays = 32
  /// Entries untouched this long are dropped.
  public static let expiryDays = 128

  public struct Entry {
    public var reading: String
    public var surface: String
    /// Uses, decayed. UInt8 is deliberate: it saturates, so a word hammered
    /// a thousand times cannot outlive one used four times by more than the
    /// cap allows.
    public var count: UInt8
    public var lastUsedDay: Int
  }

  private var table: [String: [Entry]] = [:]
  private var sortedReadings: [String] = []

  public init() {}

  public var entryCount: Int { table.values.reduce(0) { $0 + $1.count } }
  public var readingCount: Int { sortedReadings.count }

  /// Days since the reference date. Passed in rather than read from the clock
  /// so tests can move time.
  public static func day(for date: Date = Date()) -> Int {
    Int(date.timeIntervalSinceReferenceDate / 86400)
  }

  // MARK: - Updating

  public mutating func record(reading: String, surface: String, today: Int = day()) {
    let key = Kana.toHiragana(reading)
    guard !key.isEmpty, !surface.isEmpty else { return }
    var entries = table[key] ?? []
    if let index = entries.firstIndex(where: { $0.surface == surface }) {
      var entry = entries[index]
      entry = LearningStore.decayed(entry, to: today)
      entry.count = entry.count == .max ? .max : entry.count + 1
      entry.lastUsedDay = today
      entries[index] = entry
    } else {
      entries.append(Entry(reading: key, surface: surface, count: 1, lastUsedDay: today))
      if entries.count == 1 { insertReading(key) }
    }
    table[key] = entries
  }

  /// Coarse on purpose: a surface is forgotten wherever it appears under this
  /// reading. Being asked to forget a candidate and then seeing it again
  /// because some other entry spelled it the same way is worse than forgetting
  /// slightly too much. azooKey names the same choice `testCoarseForget`.
  @discardableResult
  public mutating func forget(surface: String, reading: String? = nil) -> Bool {
    var removed = false
    let keys = reading.map { [Kana.toHiragana($0)] } ?? sortedReadings
    for key in keys {
      guard var entries = table[key] else { continue }
      let before = entries.count
      entries.removeAll { $0.surface == surface }
      guard entries.count != before else { continue }
      removed = true
      if entries.isEmpty {
        table[key] = nil
        removeReading(key)
      } else {
        table[key] = entries
      }
    }
    return removed
  }

  public mutating func removeAll() {
    table = [:]
    sortedReadings = []
  }

  // MARK: - Reading

  public func entries(forReading reading: String, today: Int = day()) -> [Entry] {
    (table[Kana.toHiragana(reading)] ?? [])
      .map { LearningStore.decayed($0, to: today) }
      .filter { $0.count > 0 }
      .sorted { $0.count > $1.count }
  }

  public func entries(withPrefix prefix: String, maxKeys: Int, today: Int = day())
    -> [(String, [Entry])]
  {
    guard !prefix.isEmpty, maxKeys > 0 else { return [] }
    var results: [(String, [Entry])] = []
    var index = lowerBound(prefix)
    while index < sortedReadings.count, results.count < maxKeys {
      let reading = sortedReadings[index]
      guard reading.hasPrefix(prefix) else { break }
      let entries = entries(forReading: reading, today: today)
      if !entries.isEmpty { results.append((reading, entries)) }
      index += 1
    }
    return results
  }

  // MARK: - Decay

  static func decayed(_ entry: Entry, to today: Int) -> Entry {
    var entry = entry
    guard today > entry.lastUsedDay else { return entry }
    if today - entry.lastUsedDay >= expiryDays {
      entry.count = 0
      return entry
    }
    var elapsed = today - entry.lastUsedDay
    while elapsed >= halfLifeDays, entry.count > 0 {
      entry.count >>= 1
      elapsed -= halfLifeDays
    }
    return entry
  }

  /// Drops what has decayed to nothing. Called when saving.
  public mutating func compact(today: Int = day()) {
    for key in sortedReadings {
      let live = (table[key] ?? [])
        .map { LearningStore.decayed($0, to: today) }
        .filter { $0.count > 0 }
      if live.isEmpty {
        table[key] = nil
      } else {
        table[key] = live
      }
    }
    sortedReadings = table.keys.sorted { compareBytes(Array($0.utf8), Array($1.utf8)) < 0 }
  }

  // MARK: - Persistence

  /// `reading <TAB> surface <TAB> count <TAB> lastUsedDay`, so the file stays
  /// readable and the decay state is visible rather than hidden in a blob.
  public func serialized() -> String {
    var lines = ["# reading\tsurface\tcount\tlastUsedDay"]
    for reading in sortedReadings {
      for entry in table[reading] ?? [] {
        lines.append("\(reading)\t\(entry.surface)\t\(entry.count)\t\(entry.lastUsedDay)")
      }
    }
    return lines.joined(separator: "\n") + "\n"
  }

  public static func parse(_ text: String) -> LearningStore {
    var store = LearningStore()
    for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }
      let columns = line.components(separatedBy: "\t")
      guard columns.count >= 4, let count = UInt8(columns[2]), let day = Int(columns[3]),
        count > 0
      else { continue }
      let key = Kana.toHiragana(columns[0])
      guard !key.isEmpty, !columns[1].isEmpty else { continue }
      var entries = store.table[key] ?? []
      entries.append(Entry(reading: key, surface: columns[1], count: count, lastUsedDay: day))
      if entries.count == 1 { store.insertReading(key) }
      store.table[key] = entries
    }
    return store
  }

  public static func load(contentsOf url: URL) throws -> LearningStore {
    parse(try String(contentsOf: url, encoding: .utf8))
  }

  // MARK: - Sorted reading list

  private mutating func insertReading(_ reading: String) {
    sortedReadings.insert(reading, at: lowerBound(reading))
  }

  private mutating func removeReading(_ reading: String) {
    if let index = sortedReadings.firstIndex(of: reading) {
      sortedReadings.remove(at: index)
    }
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
}
