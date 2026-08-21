import Foundation

/// Build-time reading expansion.
///
/// A word is reachable only through readings the index was given. XSS filed
/// under くろすさいとすくりぷてぃんぐ is unreachable to anyone who types
/// えっくすえすえす, which is what people actually type. The dictionary is not
/// missing the word; it is missing the way in.
///
/// So generate the ways in once, at build time, and leave the runtime a plain
/// lookup. Nothing here is clever — it is a spelling table and a few rules —
/// and that is the point: **which readings reach a word is written down and
/// can be argued with**, rather than decided by a model at conversion time.
///
/// The store can do this expansion server-side and ship the result, which is
/// why the format that comes out is just more rows of reading and surface.
public enum Expansion {
  /// How each letter is said when a word is spelled out loud.
  ///
  /// One reading per letter, not every variant. えっくすえすえす is what
  /// someone types for XSS; generating every combination of えっち/えいち and
  /// じぇー/じぇい multiplies rows for readings nobody uses, and short readings
  /// that collide with existing words are exactly where added entries do harm.
  static let letterReadings: [Character: String] = [
    "a": "えー", "b": "びー", "c": "しー", "d": "でぃー", "e": "いー",
    "f": "えふ", "g": "じー", "h": "えいち", "i": "あい", "j": "じぇー",
    "k": "けー", "l": "える", "m": "えむ", "n": "えぬ", "o": "おー",
    "p": "ぴー", "q": "きゅー", "r": "あーる", "s": "えす", "t": "てぃー",
    "u": "ゆー", "v": "ぶい", "w": "だぶりゅー", "x": "えっくす", "y": "わい",
    "z": "ぜっと",
    "0": "ぜろ", "1": "いち", "2": "に", "3": "さん", "4": "よん",
    "5": "ご", "6": "ろく", "7": "なな", "8": "はち", "9": "きゅー",
  ]

  /// Readings that reach `surface`, given whatever readings were written down.
  ///
  /// - Parameters:
  ///   - surface: what gets inserted.
  ///   - given: readings supplied by the dictionary author, in hiragana or
  ///     katakana. Usually the full name — くろすさいとすくりぷてぃんぐ.
  public static func readings(for surface: String, given: [String]) -> [String] {
    var result: [String] = []
    var seen: Set<String> = []

    func add(_ reading: String) {
      let normalized = Kana.toHiragana(reading)
      guard !normalized.isEmpty, !seen.contains(normalized) else { return }
      seen.insert(normalized)
      result.append(normalized)
    }

    for reading in given { add(reading) }

    // Spelled out: XSS -> えっくすえすえす.
    if let spelled = spelledOut(surface) { add(spelled) }

    // Typed as-is. Someone who knows the acronym often just types it, and the
    // IME should let that through rather than making them switch input mode.
    if isAsciiWord(surface) { add(surface.lowercased()) }

    // A katakana surface is reachable by its own kana.
    if Kana.isAllKana(surface) { add(surface) }

    return result
  }

  /// `XSS` -> `えっくすえすえす`. nil when the surface is not a short run of
  /// letters and digits — spelling out a whole sentence helps nobody.
  static func spelledOut(_ surface: String) -> String? {
    guard isAsciiWord(surface), surface.count <= 8 else { return nil }
    var reading = ""
    for character in surface.lowercased() {
      guard let part = letterReadings[character] else { return nil }
      reading += part
    }
    return reading.isEmpty ? nil : reading
  }

  static func isAsciiWord(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    for scalar in text.unicodeScalars {
      let v = scalar.value
      let letter = (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
      let digit = (0x30...0x39).contains(v)
      if !(letter || digit) { return false }
    }
    return true
  }

  // MARK: - Source format

  public struct Entry {
    public var surface: String
    public var given: [String]
    public var partOfSpeech: String
  }

  /// `surface <TAB> reading[|reading...] [<TAB> part-of-speech]`
  ///
  /// Surface first, because the surface is the thing being described and the
  /// readings are the generated part. Readings may be omitted entirely for an
  /// acronym that spells out.
  public static func parseSource(_ text: String) -> [Entry] {
    text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).compactMap { rawLine in
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
      let columns = line.components(separatedBy: "\t")
      guard let surface = columns.first, !surface.isEmpty else { return nil }
      let given =
        columns.count > 1
        ? columns[1].components(separatedBy: "|")
          .map { $0.trimmingCharacters(in: .whitespaces) }
          .filter { !$0.isEmpty }
        : []
      let pos = columns.count > 2 ? columns[2] : "名詞"
      return Entry(surface: surface, given: given, partOfSpeech: pos)
    }
  }

  public struct Result {
    public var lines: [String]
    public var entries: Int
    public var readings: Int
    public var dropped: [String]
    /// Entries that produced no reading at all, and so are unreachable.
    ///
    /// This is the failure that hides: the row is in the source, the file
    /// looks right, and the word simply never appears. It happens whenever a
    /// surface contains kanji and no reading was written — no rule can invent
    /// one — and 証明書失効リスト sat in the dictionary unreachable because of
    /// exactly that.
    public var unreachable: [String]
  }

  /// Expands a source into MS-IME user dictionary rows.
  ///
  /// Readings shorter than `minimumReadingLength` are dropped. Added entries
  /// do their damage by colliding with existing short readings — measured
  /// elsewhere, a 200k-entry addition costs 8.3 points through readings that
  /// collide and nothing at all through readings of six characters or more —
  /// and expansion is what turns one long safe reading into several short
  /// dangerous ones.
  ///
  /// The floor is 3 because that is what measuring said. On a 63-term
  /// dictionary, going from 5 to 3 took coverage from 51/57 to 57/57 and moved
  /// none of the other numbers: the word set, the breakdown set and the phrase
  /// set were identical at every setting. こるす, にすと and しーむ are what
  /// people type, and nothing was paying for their absence.
  ///
  /// **That measurement does not scale.** Ten short readings among 63 terms
  /// are invisible; the harm it is guarding against was measured across
  /// 212,957 entries. A store shipping dictionaries of that size should raise
  /// this, and should measure rather than assume — as should anyone reading
  /// the number above and taking it as settled.
  public static func expand(_ entries: [Entry], minimumReadingLength: Int = 3) -> Result {
    var lines: [String] = ["!Microsoft IME Dictionary Tool"]
    var readingCount = 0
    var dropped: [String] = []
    var unreachable: [String] = []

    for entry in entries {
      var emitted = 0
      for reading in readings(for: entry.surface, given: entry.given) {
        guard reading.count >= minimumReadingLength else {
          dropped.append("\(reading) → \(entry.surface)")
          continue
        }
        lines.append("\(reading)\t\(entry.surface)\t\(entry.partOfSpeech)")
        readingCount += 1
        emitted += 1
      }
      if emitted == 0 { unreachable.append(entry.surface) }
    }

    return Result(
      lines: lines, entries: entries.count, readings: readingCount, dropped: dropped,
      unreachable: unreachable)
  }
}
