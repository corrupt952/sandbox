import Foundation

/// Segmentations the user has confirmed, remembered whole.
///
/// Every other way of joining words needs a model of how words join. A part-of
/// speech bigram matrix is one; a word bigram is another; both require the
/// dictionary to speak a vocabulary of contexts it should not have to know
/// about. This needs neither, because it does not compute the join — it
/// remembers one that already happened.
///
/// It is the same move as expanding inflections at build time. Rather than
/// deriving 書い + た at conversion time, put かいた → 書いた in the index and
/// let the runtime look it up. Rather than deriving 今日 + は, put
/// きょうは → 今日は in here. **The concept of a connection cost disappears
/// instead of being approximated.**
///
/// What makes it work now and not before is the segment UI. Committing used to
/// yield one string; now it yields a split the user looked at and accepted,
/// which is a far stronger claim than "these characters became those".
public struct SegmentationStore {
  public static let halfLifeDays = LearningStore.halfLifeDays
  public static let expiryDays = LearningStore.expiryDays

  public struct Segment: Equatable {
    public var reading: String
    public var surface: String

    public init(reading: String, surface: String) {
      self.reading = reading
      self.surface = surface
    }
  }

  public struct Entry {
    public var reading: String
    public var segments: [Segment]
    public var count: UInt8
    public var lastUsedDay: Int
  }

  private var table: [String: Entry] = [:]
  /// Readings in sorted order, for the longest-prefix search.
  private var sortedReadings: [String] = []

  public init() {}

  public var count: Int { table.count }

  // MARK: - Recording

  public mutating func record(
    segments: [Segment], today: Int = LearningStore.day()
  ) {
    let cleaned = segments.filter { !$0.reading.isEmpty }
    // A single segment is just a word, and the word layers already hold it.
    // What is worth remembering here is where the joins went.
    guard cleaned.count >= 2 else { return }
    let key = cleaned.map(\.reading).joined()
    guard !key.isEmpty else { return }

    if var existing = table[key], existing.segments == cleaned {
      existing = SegmentationStore.decayed(existing, to: today)
      existing.count = existing.count == .max ? .max : existing.count + 1
      existing.lastUsedDay = today
      table[key] = existing
    } else {
      // A different split for the same reading replaces the old one. The user
      // just corrected it; keeping the previous answer around to compete would
      // undo the correction.
      if table[key] == nil { insertReading(key) }
      table[key] = Entry(reading: key, segments: cleaned, count: 1, lastUsedDay: today)
    }
  }

  @discardableResult
  public mutating func forget(reading: String) -> Bool {
    guard table.removeValue(forKey: reading) != nil else { return false }
    if let position = sortedReadings.firstIndex(of: reading) {
      sortedReadings.remove(at: position)
    }
    return true
  }

  public mutating func removeAll() {
    table = [:]
    sortedReadings = []
  }

  // MARK: - Recall

  public func segments(for reading: String, today: Int = LearningStore.day()) -> [Segment]? {
    guard let entry = table[reading] else { return nil }
    return SegmentationStore.decayed(entry, to: today).count > 0 ? entry.segments : nil
  }

  /// The longest remembered split that starts this reading.
  ///
  /// Exact recall alone would only fire on sentences typed verbatim before.
  /// Matching a prefix means yesterday's きょうは carries into today's
  /// きょうはさむかった, which is where the value is: the openings repeat even
  /// when the sentences do not.
  public func longestPrefix(of reading: String, today: Int = LearningStore.day())
    -> (matched: String, segments: [Segment])?
  {
    guard !reading.isEmpty else { return nil }
    var best: (String, [Segment])?
    // Sorted order lets the search stop as soon as the keys pass the reading.
    var index = lowerBound(String(reading.prefix(1)))
    while index < sortedReadings.count {
      let key = sortedReadings[index]
      index += 1
      guard key.first == reading.first else {
        if compareBytes(Array(key.utf8), Array(reading.utf8)) > 0 { break }
        continue
      }
      guard reading.hasPrefix(key), key.count <= reading.count else { continue }
      guard let entry = table[key],
        SegmentationStore.decayed(entry, to: today).count > 0
      else { continue }
      if best == nil || key.count > best!.0.count { best = (key, entry.segments) }
    }
    return best.map { (matched: $0.0, segments: $0.1) }
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

  public mutating func compact(today: Int = LearningStore.day()) {
    for (key, entry) in table where SegmentationStore.decayed(entry, to: today).count == 0 {
      table[key] = nil
    }
    sortedReadings = table.keys.sorted { compareBytes(Array($0.utf8), Array($1.utf8)) < 0 }
  }

  // MARK: - Persistence

  /// `reading <TAB> reading/surface|reading/surface … <TAB> count <TAB> day`
  public func serialized() -> String {
    var lines = ["# reading\tsegments\tcount\tlastUsedDay"]
    for reading in sortedReadings {
      guard let entry = table[reading] else { continue }
      let body = entry.segments.map { "\($0.reading)/\($0.surface)" }.joined(separator: "|")
      lines.append("\(reading)\t\(body)\t\(entry.count)\t\(entry.lastUsedDay)")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  public static func parse(_ text: String) -> SegmentationStore {
    var store = SegmentationStore()
    for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }
      let columns = line.components(separatedBy: "\t")
      guard columns.count >= 4, let count = UInt8(columns[2]), let day = Int(columns[3]),
        count > 0
      else { continue }
      let segments: [Segment] = columns[1].components(separatedBy: "|").compactMap { part in
        // Surfaces may contain "/", readings never do, so split on the first.
        guard let slash = part.firstIndex(of: "/") else { return nil }
        let reading = String(part[part.startIndex..<slash])
        let surface = String(part[part.index(after: slash)...])
        guard !reading.isEmpty, !surface.isEmpty else { return nil }
        return Segment(reading: reading, surface: surface)
      }
      guard segments.count >= 2 else { continue }
      let key = columns[0]
      if store.table[key] == nil { store.insertReading(key) }
      store.table[key] = Entry(
        reading: key, segments: segments, count: count, lastUsedDay: day)
    }
    return store
  }

  public static func load(contentsOf url: URL) throws -> SegmentationStore {
    parse(try String(contentsOf: url, encoding: .utf8))
  }

  // MARK: - Sorted reading list

  private mutating func insertReading(_ reading: String) {
    sortedReadings.insert(reading, at: lowerBound(reading))
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
