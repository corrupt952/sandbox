import Foundation
import KanaKanjiCore

let usage = """
  kkc — kana-kanji conversion prototype

  USAGE
    kkc build [--format mozc|ipadic]           compile a source lexicon into kkc data
    kkc index <reading> [-n <count>]           index layer only (no lattice)
    kkc convert <reading> [-n <count>]         lattice + Viterbi (needs an ipadic build)
    kkc repl [-n <count>]                      convert line by line from stdin
    kkc eval [--set <file>] [-n <count>]       score against a test set
    kkc stats                                  show what is loaded

  OPTIONS
    --format <name>       mozc (default) or ipadic
    --source <dir>        source lexicon
                          mozc:   dict/mozc/src/data/dictionary_oss
                          ipadic: dict/src
    --out <dir>           compiled data
                          mozc:   dict/build
                          ipadic: dict/build-ipadic
    --keep-proper-nouns   mozc only; 名詞,固有名詞 is dropped by default
    --set <file>          evaluation set     (default: samples/basic.tsv)
    -n <count>            candidates to show (default: 5)

  Fetch the language resources first; they are not committed.
    scripts/fetch-mozc-dict.sh   mozc   (baseline)
    scripts/fetch-dict.sh        ipadic (comparison)
  """

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("error: \(message)\n".utf8))
  exit(1)
}

func option(_ name: String, in arguments: [String]) -> String? {
  guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
  return arguments[index + 1]
}

func directory(_ path: String) -> URL {
  URL(
    fileURLWithPath: path,
    relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  )
  .standardizedFileURL
}

/// Builds the layered index the same way for every command, so what is being
/// measured matches what the app runs.
func loadIndex(_ arguments: [String]) -> LayeredIndex {
  let out = directory(option("--out", in: arguments) ?? "dict/build")
  let index = LayeredIndex()
  do {
    let lexicon = try Lexicon(contentsOf: out.appendingPathComponent("lexicon.bin"))
    index.addCompiled(lexicon, name: "mozc", priority: .baseline)
  } catch {
    fail("\(error)\nDid you run `kkc build`?")
  }

  // Mode dictionaries are opt-out so a measurement can isolate their effect.
  if !arguments.contains("--no-modes") {
    let modes = directory(option("--modes", in: arguments) ?? "dict/mode")
    for file
      in ((try? FileManager.default.contentsOfDirectory(
        at: modes, includingPropertiesForKeys: nil)) ?? [])
      .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    where ["txt", "csv", "tsv"].contains(file.pathExtension) {
      if let dictionary = try? TextDictionary.load(contentsOf: file) {
        index.addText(dictionary, name: file.lastPathComponent, priority: .mode)
      }
    }
  }
  return index
}

/// Loads the bigram model when its files are present.
///
/// Optional on purpose: the flat boundary penalty still works without it, and
/// keeping both paths live is how the two are compared.
/// Off unless asked for.
///
/// Not because bigrams are wrong — the reference implementation reaches mozc's
/// full model with them — but because the counting behind them is not right
/// yet. The unigram and the bigram want different tokenisations: unigrams want
/// the dictionary's units, since mozc holds 勉強する and 東京都 as single
/// entries that need a count, while bigrams want morphological short units, so
/// the pairs recorded are the pairs the lattice proposes. Longest match gives
/// the first and covers 55% of the needed pairs; short units give the second
/// and leave compounds priced by their characters, which cost 22 points at
/// word level. One pass cannot serve both.
func loadBigrams(_ arguments: [String]) -> BigramModel? {
  guard arguments.contains("--bigrams-on") else { return nil }
  let interpolation = Double(option("--interpolation", in: arguments) ?? "")
    ?? BigramModel.defaultInterpolation
  let bigrams = directory(option("--bigrams", in: arguments) ?? "dict/bigrams.tsv")
  let unigrams = directory(option("--counts", in: arguments) ?? "dict/counts.tsv")
  guard FileManager.default.fileExists(atPath: bigrams.path),
    FileManager.default.fileExists(atPath: unigrams.path)
  else { return nil }
  return try? BigramModel.load(
    bigrams: bigrams, unigrams: unigrams, interpolation: interpolation)
}

func loadConverter(_ arguments: [String]) -> Converter {
  let out = directory(option("--out", in: arguments) ?? "dict/build")
  do {
    return try Converter(dataDirectory: out)
  } catch {
    fail("\(error)\nDid you run `kkc build`?")
  }
}

func printCandidates(_ candidates: [Candidate], reading: String) {
  guard !candidates.isEmpty else {
    print("(no candidate for \(reading))")
    return
  }
  for (rank, candidate) in candidates.enumerated() {
    let breakdown = candidate.segments
      .map { $0.isUnknown ? "\($0.surface)*" : $0.surface }
      .joined(separator: "|")
    print(
      String(format: "%2d. %@  (cost %d)  %@", rank + 1, candidate.text, candidate.cost, breakdown))
  }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
  print(usage)
  exit(0)
}

switch command {
case "build":
  let formatName = option("--format", in: arguments) ?? "mozc"
  guard let format = DictionaryBuilder.SourceFormat(rawValue: formatName) else {
    fail(
      "unknown format: \(formatName) "
        + "(expected \(DictionaryBuilder.SourceFormat.allCases.map(\.rawValue).joined(separator: " or ")))"
    )
  }
  let defaultSource =
    format == .mozc ? "dict/mozc/src/data/dictionary_oss" : "dict/src"
  let defaultOut = format == .mozc ? "dict/build" : "dict/build-ipadic"
  let source = directory(option("--source", in: arguments) ?? defaultSource)
  let out = directory(option("--out", in: arguments) ?? defaultOut)
  let keepProperNouns = arguments.contains("--keep-proper-nouns")
  let noInflection = arguments.contains("--no-inflection")
  let keepKanaIdentity = arguments.contains("--keep-kana-identity")
  var estimator: CorpusEstimator?
  if let countsPath = option("--counts", in: arguments) {
    do {
      estimator = try CorpusEstimator.load(contentsOf: directory(countsPath))
      print("counts: \(estimator!.surfaceCount) surfaces, \(estimator!.tokenCount) tokens")
    } catch {
      fail("\(error)\nRun `kkc estimate` first.")
    }
  }

  print("format: \(format.rawValue)")
  print("source: \(source.path)")
  print("output: \(out.path)")
  let builder = DictionaryBuilder(
    sourceDirectory: source, outputDirectory: out, format: format,
    excludeProperNouns: !keepProperNouns, expandInflections: !noInflection,
    excludeKanaIdentity: !keepKanaIdentity, estimator: estimator,
    backoff: arguments.contains("--length-backoff") ? .length : .mozc)
  do {
    let started = Date()
    let stats = try builder.build { print($0) }
    print("")
    print("entries:  \(stats.entryCount)")
    print("keys:     \(stats.keyCount)")
    print("skipped:  \(stats.skippedRows) rows")
    if let matrix = stats.matrixSize {
      print("matrix:   \(matrix.left) x \(matrix.right)")
    } else {
      print("matrix:   (none — index layer only; the lattice layer needs an ipadic build)")
    }
    print("elapsed:  \(String(format: "%.1fs", Date().timeIntervalSince(started)))")
  } catch {
    fail("\(error)")
  }

case "convert":
  guard let reading = arguments.dropFirst().first, !reading.hasPrefix("-") else {
    fail("convert needs a reading, e.g. kkc convert きょうはいいてんきですね")
  }
  let count = Int(option("-n", in: arguments) ?? "") ?? 5
  let converter = loadConverter(arguments)
  printCandidates(converter.convert(reading, count: count), reading: reading)

case "repl":
  let count = Int(option("-n", in: arguments) ?? "") ?? 5
  let converter = loadConverter(arguments)
  print("reading > (ctrl-d to quit)")
  while let line = readLine(strippingNewline: true) {
    let reading = line.trimmingCharacters(in: .whitespaces)
    if reading.isEmpty { continue }
    printCandidates(converter.convert(reading, count: count), reading: reading)
  }

case "expand":
  let source = directory(option("--source", in: arguments) ?? "dict-src")
  let out = directory(option("--out", in: arguments) ?? "dict/mode")
  let minimum = Int(option("--min-reading", in: arguments) ?? "") ?? 3
  let sources =
    ((try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil))
    ?? [])
    .filter { $0.pathExtension == "tsv" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
  guard !sources.isEmpty else { fail("no .tsv sources in \(source.path)") }

  try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
  for file in sources {
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
    let result = Expansion.expand(Expansion.parseSource(text), minimumReadingLength: minimum)
    let destination = out.appendingPathComponent(file.lastPathComponent)
    do {
      try (result.lines.joined(separator: "\n") + "\n")
        .write(to: destination, atomically: true, encoding: .utf8)
    } catch {
      fail("\(error)")
    }
    let perEntry = Double(result.readings) / Double(max(result.entries, 1))
    print(
      String(
        format: "%@: %d entries → %d readings (%.1f each)", file.lastPathComponent,
        result.entries, result.readings, perEntry))
    if !result.dropped.isEmpty {
      print("  dropped \(result.dropped.count) readings shorter than \(minimum):")
      for item in result.dropped.prefix(8) { print("    \(item)") }
    }
    if !result.unreachable.isEmpty {
      print("  UNREACHABLE — no reading could be generated, add one to the source:")
      for item in result.unreachable { print("    \(item)") }
    }
    print("  → \(destination.path)")
  }

case "scan":
  // Counts surfaces and adjacent pairs in raw text, using the built lexicon to
  // decide where words end. Unigrams price entries; bigrams are what replaces
  // a part-of-speech connection matrix.
  let corpus = directory(option("--corpus", in: arguments) ?? "dict/corpus")
  let unigramOut = directory(option("--counts", in: arguments) ?? "dict/counts.tsv")
  let bigramOut = directory(option("--bigrams", in: arguments) ?? "dict/bigrams.tsv")
  let lineLimit = Int(option("--lines", in: arguments) ?? "") ?? Int.max
  let minimumBigram = Int(option("--min-bigram", in: arguments) ?? "") ?? 2
  let tokenised = arguments.contains("--tokenised")

  let lexiconURL = directory(option("--out", in: arguments) ?? "dict/build")
    .appendingPathComponent("lexicon.bin")
  guard let lexicon = try? Lexicon(contentsOf: lexiconURL) else {
    fail("cannot read \(lexiconURL.path)\nRun `kkc build` first.")
  }
  print("lexicon: \(lexicon.numberOfEntries) entries")
  let surfaces = lexicon.allSurfaces()
  print("surfaces: \(surfaces.count)")

  let scanner = SurfaceScanner(surfaces: surfaces)
  var counts = SurfaceScanner.Counts()
  var files: [URL] = []
  if let enumerator = FileManager.default.enumerator(
    at: corpus, includingPropertiesForKeys: nil)
  {
    for case let url as URL in enumerator where url.pathExtension == "txt" {
      files.append(url)
    }
  }
  guard !files.isEmpty else { fail("no .txt corpus under \(corpus.path)") }

  let started = Date()
  var lines = 0
  outer: for file in files.sorted(by: { $0.path < $1.path }) {
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
    print("  \(file.lastPathComponent)")
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
      if tokenised {
        scanner.scanTokenised(line, into: &counts)
      } else {
        scanner.scan(line, into: &counts)
      }
      lines += 1
      if lines >= lineLimit { break outer }
      if lines % 100_000 == 0 {
        print(
          "    \(lines) lines, \(counts.tokens) tokens, "
            + String(format: "%.0fs", Date().timeIntervalSince(started)))
      }
    }
  }

  print("")
  print("lines:     \(lines)")
  print("tokens:    \(counts.tokens)")
  print("unigrams:  \(counts.unigrams.count)")
  print("bigrams:   \(counts.bigrams.count) (before pruning)")
  print("unmatched: \(counts.unmatched) characters")

  do {
    var unigramLines = ["# surface\tcount\ttotal=\(counts.tokens)"]
    for (surface, count) in counts.unigrams.sorted(by: { $0.value > $1.value }) {
      unigramLines.append("\(surface)\t\(count)")
    }
    // Character counts ride in the unigram file, marked so the parser can tell
    // them apart. They are what prices a surface the corpus never saw.
    let characterTotal = counts.characters.values.reduce(0, +)
    unigramLines.append("# characters total=\(characterTotal)")
    for (character, count) in counts.characters.sorted(by: { $0.value > $1.value }) {
      unigramLines.append("\u{1}\(character)\t\(count)")
    }
    try (unigramLines.joined(separator: "\n") + "\n")
      .write(to: unigramOut, atomically: true, encoding: .utf8)

    // Singletons are noise and most of the file; pruning them is what makes
    // the model fit in memory.
    var kept = 0
    var bigramLines = ["# previous\tsurface\tcount"]
    for (key, count) in counts.bigrams where count >= minimumBigram {
      let parts = key.split(separator: "\u{1}")
      guard parts.count == 2 else { continue }
      bigramLines.append("\(parts[0])\t\(parts[1])\t\(count)")
      kept += 1
    }
    try (bigramLines.joined(separator: "\n") + "\n")
      .write(to: bigramOut, atomically: true, encoding: .utf8)
    print("kept:      \(kept) bigrams seen \(minimumBigram)+ times")
    print("wrote:     \(unigramOut.path)")
    print("           \(bigramOut.path)")
  } catch {
    fail("\(error)")
  }

case "estimate":
  let corpus = directory(option("--corpus", in: arguments) ?? "dict/corpus/ud-japanese-gsd")
  let countsOut = directory(option("--counts", in: arguments) ?? "dict/counts.tsv")
  // The test split is held out so the estimate cannot see what it is scored on.
  let files =
    ((try? FileManager.default.contentsOfDirectory(at: corpus, includingPropertiesForKeys: nil))
    ?? [])
    .filter { $0.pathExtension == "conllu" && !$0.lastPathComponent.contains("test") }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
  guard !files.isEmpty else {
    fail("no .conllu files in \(corpus.path)\nRun scripts/fetch-corpus.sh first.")
  }

  let sentenceLimit = Int(option("--sentences", in: arguments) ?? "")
  var estimator = CorpusEstimator()
  for file in files {
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
    let stats = estimator.ingestCoNLLU(text, sentenceLimit: sentenceLimit)
    print(
      "\(file.lastPathComponent): \(stats.sentences) sentences, \(stats.tokens) tokens, "
        + "\(stats.compounds) compounds")
  }
  print("")
  print("counted:  \(estimator.tokenCount)")
  print("surfaces: \(estimator.surfaceCount)")
  do {
    try estimator.serialized().write(to: countsOut, atomically: true, encoding: .utf8)
    print("wrote:  \(countsOut.path)")
  } catch {
    fail("\(error)")
  }

case "index":
  // The index layer on its own: reading -> candidates, no lattice, no Viterbi.
  guard let reading = arguments.dropFirst().first, !reading.hasPrefix("-") else {
    fail("index needs a reading, e.g. kkc index かんじへんかん")
  }
  let count = Int(option("-n", in: arguments) ?? "") ?? 10
  let index = loadIndex(arguments)

  let started = Date()
  let found = index.candidates(for: reading, limit: count)
  let elapsed = Date().timeIntervalSince(started) * 1000
  for (rank, candidate) in found.enumerated() {
    print(
      String(
        format: "%2d. %-16@ %-16@ %-9@ %6d%@", rank + 1, candidate.surface as NSString,
        candidate.reading as NSString, candidate.layerName as NSString, candidate.cost,
        candidate.isExact ? "" : "  (predicted)"))
  }
  print(String(format: "\n%d candidates in %.2f ms", found.count, elapsed))

case "segment":
  guard let reading = arguments.dropFirst().first, !reading.hasPrefix("-") else {
    fail("segment needs a reading, e.g. kkc segment きょうはあつかった")
  }
  let count = Int(option("-n", in: arguments) ?? "") ?? 5
  let lambda = Int32(option("--lambda", in: arguments) ?? "") ?? 5000
  let interpolation = Double(option("--interpolation", in: arguments) ?? "") ?? BigramModel.defaultInterpolation
  let index = loadIndex(arguments)

  var configuration = SegmentingConverter.Configuration()
  configuration.boundaryCost = lambda
  let segmenter = SegmentingConverter(
    index: index, configuration: configuration, bigrams: loadBigrams(arguments))

  let started = Date()
  let results = segmenter.convert(reading, count: count)
  let elapsed = Date().timeIntervalSince(started) * 1000

  print("λ = \(lambda)\n")
  for (rank, result) in results.enumerated() {
    let split = result.segments.map { $0.surface + "(" + $0.reading + ")" }.joined(separator: " | ")
    print(String(format: "%2d. %@", rank + 1, result.text))
    print(String(format: "    cost %-7d %@", result.cost, split))
  }
  print(String(format: "\n%d results in %.1f ms", results.count, elapsed))

case "eval":
  let count = Int(option("-n", in: arguments) ?? "") ?? 5
  let engine = option("--engine", in: arguments) ?? "index"
  let verbose = arguments.contains("-v")
  let setPath = option("--set", in: arguments) ?? "samples"
  let setURL = directory(setPath)

  // A file scores one set; a directory scores each set separately, which is
  // the whole reason the sets are split by difficulty.
  var setFiles: [URL] = []
  var isDirectory: ObjCBool = false
  if FileManager.default.fileExists(atPath: setURL.path, isDirectory: &isDirectory),
    isDirectory.boolValue
  {
    setFiles =
      ((try? FileManager.default.contentsOfDirectory(
        at: setURL, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.pathExtension == "tsv" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  } else {
    setFiles = [setURL]
  }
  guard !setFiles.isEmpty else { fail("no test sets found at \(setURL.path)") }

  let convert: (String, Int) -> [String]
  switch engine {
  case "index":
    let index = loadIndex(arguments)
    convert = { reading, limit in
      index.candidates(for: reading, limit: limit).map(\.surface)
    }
  case "segment":
    let index = loadIndex(arguments)
    var configuration = SegmentingConverter.Configuration()
    configuration.boundaryCost = Int32(option("--lambda", in: arguments) ?? "") ?? 5000
    let segmenter = SegmentingConverter(
      index: index, configuration: configuration, bigrams: loadBigrams(arguments))
    convert = { reading, limit in
      segmenter.convert(reading, count: limit).map(\.text)
    }

  case "lattice":
    let out = directory(option("--out", in: arguments) ?? "dict/build-ipadic")
    let converter: Converter
    do {
      converter = try Converter(dataDirectory: out)
    } catch {
      fail("\(error)\nThe lattice layer needs `kkc build --format ipadic`.")
    }
    convert = { reading, limit in
      converter.convert(reading, count: limit).map(\.text)
    }
  default:
    fail("unknown engine: \(engine) (expected index or lattice)")
  }

  print("engine: \(engine)\n")
  var totalCases = 0
  var totalTop1 = 0
  var totalCovered = 0

  for file in setFiles {
    guard let text = try? String(contentsOf: file, encoding: .utf8) else {
      print("skipped unreadable set: \(file.lastPathComponent)")
      continue
    }
    let cases = Evaluator.parseTestSet(text)
    guard !cases.isEmpty else { continue }
    let report = Evaluator.run(cases: cases, candidateCount: count, convert: convert)

    print(
      String(
        format: "%@ top-1 %2d/%-2d (%3.0f%%)   in top-%d %2d/%-2d (%3.0f%%)",
        file.deletingPathExtension().lastPathComponent.padding(
          toLength: 12, withPad: " ", startingAt: 0) as NSString, report.top1, report.total,
        report.top1Rate * 100, count, report.covered, report.total, report.coverageRate * 100))

    if verbose {
      for result in report.results where !result.isTop1 {
        let mark = result.topRank.map { "#\($0 + 1)" } ?? "MISS"
        print(
          "  \(mark.padding(toLength: 5, withPad: " ", startingAt: 0))\(result.testCase.reading)")
        print("        got:      \(result.candidates.first ?? "-")")
        print("        expected: \(result.testCase.accepted.joined(separator: " | "))")
      }
      print("")
    }

    totalCases += report.total
    totalTop1 += report.top1
    totalCovered += report.covered
  }

  if setFiles.count > 1 {
    print(
      String(
        format: "\n%@ top-1 %2d/%-2d (%3.0f%%)   in top-%d %2d/%-2d (%3.0f%%)",
        "(all)".padding(toLength: 12, withPad: " ", startingAt: 0) as NSString, totalTop1,
        totalCases,
        Double(totalTop1) / Double(max(totalCases, 1)) * 100, count, totalCovered, totalCases,
        Double(totalCovered) / Double(max(totalCases, 1)) * 100))
  }

case "stats":
  let converter = loadConverter(arguments)
  print("lexicon entries: \(converter.lexiconEntryCount)")
  print("lexicon keys:    \(converter.lexiconKeyCount)")
  print("context ids:     \(converter.contextSize.left) x \(converter.contextSize.right)")

case "-h", "--help", "help":
  print(usage)

default:
  fail("unknown command: \(command)\n\n\(usage)")
}
