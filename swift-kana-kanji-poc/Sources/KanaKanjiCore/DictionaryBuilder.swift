import Foundation

/// Compiles a source lexicon into the files the converter loads.
///
/// Two sources are supported, and they differ in more than syntax.
///
/// - **mozc** is keyed by reading already, and that reading is written the way
///   it is typed: 助詞 は stays は, 講師 reads こうし rather than こーし.
///   Inflected forms are expanded into their own rows, so `かいた → 書いた` is
///   a plain lookup with no conjugation engine. This is the baseline.
/// - **ipadic** is a morphological analysis dictionary keyed by surface form,
///   so the index has to be rebuilt on the reading field (column 12). Kept for
///   comparison, and because the lattice layer already runs on its connection
///   matrix.
///
/// The two use different context-ID spaces (mozc 2672, ipadic 1316), so a mozc
/// lexicon can never be paired with an ipadic matrix.
public struct DictionaryBuilder {
  public enum SourceFormat: String, CaseIterable {
    case mozc
    case ipadic
  }

  public struct Stats {
    public var entryCount: Int
    public var keyCount: Int
    public var skippedRows: Int
    /// nil when the source ships no connection matrix (mozc path).
    public var matrixSize: (left: Int, right: Int)?
  }

  private let sourceDirectory: URL
  private let outputDirectory: URL
  private let format: SourceFormat
  private let excludeProperNouns: Bool
  private let expandInflections: Bool
  private let excludeKanaIdentity: Bool
  /// When present, mozc's costs are replaced by counts from real text.
  private let estimator: CorpusEstimator?
  private let backoff: Backoff

  public init(
    sourceDirectory: URL, outputDirectory: URL, format: SourceFormat = .mozc,
    excludeProperNouns: Bool = true, expandInflections: Bool = true,
    excludeKanaIdentity: Bool = true, estimator: CorpusEstimator? = nil,
    backoff: Backoff = .mozc
  ) {
    self.backoff = backoff
    self.sourceDirectory = sourceDirectory
    self.outputDirectory = outputDirectory
    self.format = format
    self.excludeProperNouns = excludeProperNouns
    self.expandInflections = expandInflections
    self.excludeKanaIdentity = excludeKanaIdentity
    self.estimator = estimator
  }

  /// The cost an entry enters the index with.
  ///
  /// With a corpus, a surface the text actually contains gets `-log(p)` and
  /// everything else gets a length-proportional backoff. Without one, mozc's
  /// number is used as-is — which is what the whole exercise is trying to stop
  /// doing, but it keeps the old behaviour available for comparison.
  private func entryCost(reading: String, surface: String, mozcCost: Int32) -> Int32 {
    guard let estimator else { return mozcCost }
    if let estimated = estimator.cost(surface: surface) { return estimated }
    return backoff == .length
      ? CorpusEstimator.backoffCost(readingLength: reading.count)
      : mozcCost
  }

  /// What to charge for a surface the corpus never saw.
  ///
  /// The clean answer is `.length` — one scale throughout, and the length term
  /// is what removes the need for a boundary penalty. It also needs a corpus
  /// big enough to have seen the vocabulary. At 205k tokens covering 37k
  /// surfaces against 1.6M readings, most of the dictionary falls to the
  /// backoff and flattens; measured, word-level accuracy drops 89% → 80%.
  ///
  /// `.mozc` keeps mozc's number for anything unseen. It mixes two scales,
  /// which is exactly the sin this whole exercise is about — but it only
  /// applies where the corpus is silent, and it lets the estimate fix the
  /// words it does know while coverage is still thin.
  public enum Backoff {
    case length
    case mozc
  }

  public func build(log: (String) -> Void = { _ in }) throws -> Stats {
    try FileManager.default.createDirectory(
      at: outputDirectory, withIntermediateDirectories: true)

    log("compiling lexicon (\(format.rawValue))...")
    let lexicon: LexiconStats
    switch format {
    case .mozc: lexicon = try buildMozcLexicon(log: log)
    case .ipadic: lexicon = try buildLexicon(log: log)
    }

    var matrixSize: (left: Int, right: Int)?
    if format == .ipadic {
      log("compiling connection matrix...")
      matrixSize = try buildMatrix()
      log("copying unknown-word definitions...")
      try copy("char.def")
      try copy("unk.def")
    }

    return Stats(
      entryCount: lexicon.entryCount, keyCount: lexicon.keyCount,
      skippedRows: lexicon.skippedRows, matrixSize: matrixSize)
  }

  // MARK: - mozc

  /// mozc rows are `reading \t leftId \t rightId \t cost \t surface`, UTF-8,
  /// reading already in hiragana.
  private func buildMozcLexicon(log: (String) -> Void) throws -> LexiconStats {
    let urls = try FileManager.default
      .contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix("dictionary") && $0.pathExtension == "txt" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !urls.isEmpty else {
      throw FormatError.missingResource("\(sourceDirectory.path)/dictionary0*.txt")
    }

    let properNounIds = excludeProperNouns ? try loadProperNounIds() : []
    if excludeProperNouns {
      log("  excluding \(properNounIds.count) personal-name context ids")
    }
    let features = (expandInflections || excludeKanaIdentity) ? try loadFeatures() : [:]

    var entries: [RawEntry] = []
    entries.reserveCapacity(expandInflections ? 2_200_000 : 1_100_000)
    var skipped = 0
    var expanded = 0

    for url in urls {
      let text = try String(contentsOf: url, encoding: .utf8)
      for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 5,
          let leftId = UInt16(fields[1]), let rightId = UInt16(fields[2]),
          let cost = Int32(fields[3])
        else {
          skipped += 1
          continue
        }
        // Readings with anything but hiragana and the prolonged mark are
        // symbol entries (!, $, CJKごかんかんじ...) that kana input never hits.
        guard isPlainHiraganaReading(fields[0]) else {
          skipped += 1
          continue
        }
        guard !properNounIds.contains(leftId) else {
          skipped += 1
          continue
        }

        let reading = String(fields[0])
        let surface = String(fields[4])

        let feature = features[leftId]
        if excludeKanaIdentity,
          shouldDropKanaIdentity(reading: reading, surface: surface, feature: feature)
        {
          skipped += 1
          continue
        }
        let form = feature?.conjugationForm ?? "*"
        let type = feature?.conjugationType ?? "*"
        let inflectable = expandInflections && feature.map(Inflection.isInflectable) == true
        let isSuruNoun = inflectable && feature.map(Inflection.isSuruNoun) == true

        // A stem like 書い is not a word; only its expansions belong in the
        // index. Emitting it unexpanded is what made かいた return nothing but
        // place names. サ変 nouns are words on their own (勉強), so they stay.
        let hideStem = inflectable && !isSuruNoun && Inflection.isStemOnly(form: form)
        if !hideStem {
          entries.append(
            RawEntry(
              key: Array(reading.utf8), surface: surface, leftId: leftId, rightId: rightId,
              cost: Int16(clamping: entryCost(reading: reading, surface: surface, mozcCost: cost))))
        }

        guard inflectable else { continue }
        let suffixes =
          isSuruNoun
          ? Inflection.suruSuffixes
          : Inflection.suffixes(form: form, type: type, stemReading: reading)
        for suffix in suffixes {
          expanded += 1
          let expandedReading = reading + suffix.reading
          let expandedSurface = surface + suffix.surface
          // An inflected form is usually absent from the corpus even when its
          // stem is common, so fall back to the stem's cost rather than to the
          // length backoff — 書いた should not be priced as if 書く were rare.
          let base =
            estimator?.cost(surface: expandedSurface)
            ?? entryCost(reading: reading, surface: surface, mozcCost: cost)
          entries.append(
            RawEntry(
              key: Array(expandedReading.utf8), surface: expandedSurface,
              leftId: leftId, rightId: rightId,
              // Slightly worse than the stem so the plain form still leads
              // when both are reachable.
              cost: Int16(clamping: base + 20)))
        }
      }
      log("  \(url.lastPathComponent): \(entries.count) entries so far")
    }
    if expandInflections {
      log("  inflection expansion added \(expanded) entries")
    }

    // Sort by cost within a reading, not just by reading.
    //
    // mozc lists the same surface more than once under different context IDs,
    // and the costs are nowhere near each other: 結果 appears at 15263 under a
    // generic noun ID and at **1** under a lexicalised one (1918, whose
    // feature string is literally 名詞,副詞可能,*,*,*,*,結果). Deduplicating by
    // (reading, surface) in file order threw the cheap one away and left 結果
    // ranked below 欠課 and 決河. The dictionary was right all along.
    entries.sort {
      let order = compareBytes($0.key, $1.key)
      if order != 0 { return order < 0 }
      return $0.cost < $1.cost
    }
    return try writeLexicon(entries: entries, skipped: skipped)
  }

  /// Context IDs to drop: personal names only.
  ///
  /// Dropping all of 名詞,固有名詞 looks attractive on paper -- it is a third
  /// of the rows and costs almost nothing against a general-vocabulary
  /// yardstick. But that yardstick (分類語彙表) excludes proper nouns by
  /// construction, so it cannot see the damage: 東京 is 固有名詞,地域,都名 and
  /// disappears with it. A baseline that cannot convert 東京 is not staying
  /// out of the way.
  ///
  /// Personal names are the part that is both huge and rarely wanted:
  /// 姓 148,575 + 名 58,746 + 一般 5,748 rows, and they are the main source of
  /// fan-out on short readings. 地域 / 組織 / 一般 stay.
  private func loadFeatures() throws -> [UInt16: Inflection.Feature] {
    let url = sourceDirectory.appendingPathComponent("id.def")
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw FormatError.missingResource(url.path)
    }
    return Inflection.parseIdDef(try String(contentsOf: url, encoding: .utf8))
  }

  private func loadProperNounIds() throws -> Set<UInt16> {
    let url = sourceDirectory.appendingPathComponent("id.def")
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw FormatError.missingResource(url.path)
    }
    var ids: Set<UInt16> = []
    let text = try String(contentsOf: url, encoding: .utf8)
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
      let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
      guard parts.count == 2, let id = UInt16(parts[0]) else { continue }
      if parts[1].hasPrefix("名詞,固有名詞,人名") { ids.insert(id) }
    }
    return ids
  }

  /// Whether an entry whose surface *is* its reading should stay out of the
  /// index.
  ///
  /// mozc carries these (けっか→けっか at cost 6594, きょうと→キョウト,
  /// こと→コト) and they beat the word they compete with — 結果 sits at rank 6
  /// behind its own reading. Fixing that with costs is the wrong move:
  /// character-type conversion is derivable from the reading and needs no
  /// dictionary, so these belong at the tail of every candidate list rather
  /// than in the competition.
  ///
  /// But not all of them. For a particle, an interjection or an adverb the
  /// kana *is* the answer — は, ありがとう, ちょっと — and deleting those loses
  /// words that nothing else supplies. So the rule splits:
  ///
  /// - **katakana form: always drop.** It is a display transform of the
  ///   reading in every case, チョット as much as コト.
  /// - **hiragana form: drop for nouns only.** けっか and こと are nouns
  ///   spelled out; は and ちょっと are not nouns and stay.
  private func shouldDropKanaIdentity(
    reading: String, surface: String, feature: Inflection.Feature?
  ) -> Bool {
    if surface == Kana.toKatakana(reading) { return true }
    if surface == reading { return feature?.partOfSpeech == "名詞" }
    return false
  }

  private func isPlainHiraganaReading(_ reading: some StringProtocol) -> Bool {
    guard !reading.isEmpty else { return false }
    for scalar in reading.unicodeScalars {
      let v = scalar.value
      if (0x3041...0x3096).contains(v) { continue }
      if v == 0x30FC { continue }  // ー
      return false
    }
    return true
  }

  // MARK: - Lexicon

  private struct RawEntry {
    var key: [UInt8]
    var surface: String
    var leftId: UInt16
    var rightId: UInt16
    var cost: Int16
  }

  private struct LexiconStats {
    var entryCount: Int
    var keyCount: Int
    var skippedRows: Int
  }

  private func buildLexicon(log: (String) -> Void) throws -> LexiconStats {
    let csvURLs = try FileManager.default
      .contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "csv" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !csvURLs.isEmpty else {
      throw FormatError.missingResource("\(sourceDirectory.path)/*.csv")
    }

    var entries: [RawEntry] = []
    entries.reserveCapacity(400_000)
    var skipped = 0

    for url in csvURLs {
      let text = try String(contentsOf: url, encoding: .utf8)
      for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        let fields = SourceParsing.splitCSV(line)
        guard fields.count >= 5,
          let leftId = UInt16(fields[1]), let rightId = UInt16(fields[2]),
          let cost = Int32(fields[3])
        else {
          skipped += 1
          continue
        }
        guard let reading = readingKey(fields: fields) else {
          skipped += 1
          continue
        }
        entries.append(
          RawEntry(
            key: Array(reading.utf8), surface: fields[0], leftId: leftId, rightId: rightId,
            cost: Int16(clamping: cost)))
      }
      log("  \(url.lastPathComponent): \(entries.count) entries so far")
    }

    entries.sort { lhs, rhs in
      compareBytes(lhs.key, rhs.key) < 0
    }

    return try writeLexicon(entries: entries, skipped: skipped)
  }

  /// ipadic column 12 (index 11) is the reading in katakana. Rows without one
  /// -- punctuation, mostly -- fall back to their surface when it is already
  /// kana, and are dropped otherwise: a kanji surface with no reading cannot be
  /// reached from kana input.
  private func readingKey(fields: [String]) -> String? {
    if fields.count > 11, fields[11] != "*", !fields[11].isEmpty {
      let key = Kana.toHiragana(fields[11])
      return key.isEmpty ? nil : key
    }
    if Kana.isAllKana(fields[0]) {
      return Kana.toHiragana(fields[0])
    }
    return nil
  }

  private func writeLexicon(entries: [RawEntry], skipped: Int) throws -> LexiconStats {
    // Group the sorted entries by key so a lookup resolves to a contiguous run.
    var keyRecords: [UInt8] = []
    var entryRecords: [UInt8] = []
    var strings: [UInt8] = []
    var stringOffsets: [String: UInt32] = [:]
    var keyOffsets: [[UInt8]: UInt32] = [:]
    var keyCount = 0

    keyRecords.reserveCapacity(entries.count * 12 / 4)
    entryRecords.reserveCapacity(entries.count * 12)
    strings.reserveCapacity(4 * 1024 * 1024)

    func intern(_ text: String) -> (offset: UInt32, length: UInt16) {
      let bytes = Array(text.utf8)
      let length = UInt16(clamping: bytes.count)
      if let offset = stringOffsets[text] { return (offset, length) }
      let offset = UInt32(strings.count)
      strings.append(contentsOf: bytes)
      stringOffsets[text] = offset
      return (offset, length)
    }

    func internKey(_ bytes: [UInt8]) -> (offset: UInt32, length: UInt16) {
      if let offset = keyOffsets[bytes] { return (offset, UInt16(clamping: bytes.count)) }
      let offset = UInt32(strings.count)
      strings.append(contentsOf: bytes)
      keyOffsets[bytes] = offset
      return (offset, UInt16(clamping: bytes.count))
    }

    var index = 0
    while index < entries.count {
      let key = entries[index].key
      var end = index
      while end < entries.count, entries[end].key == key { end += 1 }

      let keyString = internKey(key)
      LE.append(keyString.offset, to: &keyRecords)
      LE.append(keyString.length, to: &keyRecords)
      LE.append(UInt16(clamping: end - index), to: &keyRecords)
      LE.append(UInt32(index), to: &keyRecords)
      keyCount += 1

      for entry in entries[index..<end] {
        let surface = intern(entry.surface)
        LE.append(surface.offset, to: &entryRecords)
        LE.append(surface.length, to: &entryRecords)
        LE.append(entry.leftId, to: &entryRecords)
        LE.append(entry.rightId, to: &entryRecords)
        LE.append(entry.cost, to: &entryRecords)
      }
      index = end
    }

    var output: [UInt8] = []
    output.reserveCapacity(keyRecords.count + entryRecords.count + strings.count + 16)
    output.append(contentsOf: Array("KKCD".utf8))
    LE.append(Lexicon.formatVersion, to: &output)
    LE.append(UInt32(keyCount), to: &output)
    LE.append(UInt32(entries.count), to: &output)
    output.append(contentsOf: keyRecords)
    output.append(contentsOf: entryRecords)
    output.append(contentsOf: strings)

    try Data(output).write(to: outputDirectory.appendingPathComponent("lexicon.bin"))
    return LexiconStats(entryCount: entries.count, keyCount: keyCount, skippedRows: skipped)
  }

  // MARK: - Connection matrix

  /// matrix.def is ~1.7M lines of `leftId rightId cost`, so it is parsed at the
  /// byte level rather than through String splitting.
  private func buildMatrix() throws -> (left: Int, right: Int) {
    let url = sourceDirectory.appendingPathComponent("matrix.def")
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw FormatError.missingResource(url.path)
    }
    let data = try Data(contentsOf: url, options: .mappedIfSafe)

    var costs: [Int16] = []
    var leftSize = 0
    var rightSize = 0
    var headerSeen = false

    try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
      var index = 0
      let count = buffer.count
      var numbers: [Int] = []
      numbers.reserveCapacity(3)

      while index < count {
        numbers.removeAll(keepingCapacity: true)
        // Read up to the end of the line, collecting signed integers.
        while index < count, buffer[index] != 0x0A {
          let byte = buffer[index]
          if byte == 0x2D || (byte >= 0x30 && byte <= 0x39) {
            var negative = false
            if byte == 0x2D {
              negative = true
              index += 1
            }
            var value = 0
            while index < count, buffer[index] >= 0x30, buffer[index] <= 0x39 {
              value = value * 10 + Int(buffer[index] - 0x30)
              index += 1
            }
            numbers.append(negative ? -value : value)
          } else {
            index += 1
          }
        }
        index += 1  // consume the newline

        if !headerSeen {
          guard numbers.count >= 2 else { continue }
          leftSize = numbers[0]
          rightSize = numbers[1]
          headerSeen = true
          costs = [Int16](repeating: 0, count: leftSize * rightSize)
          continue
        }
        guard numbers.count >= 3 else { continue }
        let lid = numbers[0]
        let rid = numbers[1]
        guard lid < leftSize, rid < rightSize else { continue }
        // MeCab indexes as matrix[leftNode.rightId + rightNode.leftId * lsize].
        costs[lid + rid * leftSize] = Int16(clamping: numbers[2])
      }

      if !headerSeen { throw FormatError.malformedSource("matrix.def has no header") }
    }

    var output: [UInt8] = []
    output.reserveCapacity(costs.count * 2 + 16)
    output.append(contentsOf: Array("KKCM".utf8))
    LE.append(ConnectionMatrix.formatVersion, to: &output)
    LE.append(UInt32(leftSize), to: &output)
    LE.append(UInt32(rightSize), to: &output)
    for cost in costs { LE.append(cost, to: &output) }

    try Data(output).write(to: outputDirectory.appendingPathComponent("matrix.bin"))
    return (leftSize, rightSize)
  }

  private func copy(_ name: String) throws {
    let source = sourceDirectory.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: source.path) else {
      throw FormatError.missingResource(source.path)
    }
    let destination = outputDirectory.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.copyItem(at: source, to: destination)
  }
}

/// Lexicographic comparison on raw UTF-8, matching the order the runtime
/// binary search relies on.
func compareBytes(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
  let shared = min(lhs.count, rhs.count)
  var index = 0
  while index < shared {
    if lhs[index] != rhs[index] { return lhs[index] < rhs[index] ? -1 : 1 }
    index += 1
  }
  if lhs.count == rhs.count { return 0 }
  return lhs.count < rhs.count ? -1 : 1
}
