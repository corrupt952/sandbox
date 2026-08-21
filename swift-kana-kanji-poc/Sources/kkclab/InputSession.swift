import AppKit
import Foundation
import KanaKanjiCore

/// The IME state machine, without an IME.
///
/// InputMethodKit would put this behind an input source that has to be
/// installed, logged back in for, and that takes your typing down with it when
/// it breaks. The behaviour under test is the same either way, so it runs in a
/// window instead.
@MainActor
final class InputSession: ObservableObject {
  // Committed text, and the composition in progress.
  @Published private(set) var committed = ""
  @Published private(set) var kana = ""
  @Published private(set) var romajiPending = ""

  @Published private(set) var candidates: [LayeredIndex.Candidate] = []
  @Published private(set) var selection = 0
  @Published private(set) var isSelecting = false
  /// The reading split into segments, once Space has been pressed.
  @Published private(set) var composition = Composition()

  // What the experiment is actually here to show.
  @Published private(set) var lastLookupMicroseconds = 0
  @Published private(set) var layerSummary:
    [(name: String, priority: LayeredIndex.Priority, readings: Int)] = []
  @Published private(set) var userDictionaryEntries = 0
  @Published private(set) var learnedEntries = 0
  @Published private(set) var rememberedSegmentations = 0
  @Published private(set) var status = ""

  /// MS-IME writes its auto-tuning results into the user dictionary rather
  /// than into the language model. Same thing here: committing a candidate
  /// teaches the top layer, so learning and installed dictionaries share one
  /// mechanism.
  @Published var learnOnCommit = true
  @Published var predictionEnabled = true

  private let index = LayeredIndex()
  private lazy var segmenter = SegmentingConverter(
    index: index, bigrams: bigrams)
  private var bigrams: BigramModel?
  private var userDictionary = TextDictionary(entries: [])
  private var learning = LearningStore()
  private var remembered = SegmentationStore()
  private let userDictionaryURL: URL
  private let learningURL: URL
  private let segmentationURL: URL

  private static let userLayerName = "user.txt"
  private static let learnedLayerName = "learned.tsv"

  init(
    dataDirectory: URL, modeDirectory: URL, userDictionaryURL: URL, learningURL: URL,
    segmentationURL: URL
  ) {
    self.userDictionaryURL = userDictionaryURL
    self.learningURL = learningURL
    self.segmentationURL = segmentationURL

    do {
      let lexicon = try Lexicon(contentsOf: dataDirectory.appendingPathComponent("lexicon.bin"))
      index.addCompiled(lexicon, name: "mozc", priority: .baseline)
      status = "baseline: \(lexicon.numberOfKeys) readings"
    } catch {
      status = "baseline unavailable: \(error). Run `kkc build` first."
    }

    // Mode dictionaries are optional; the point of the layer is that it can be
    // empty and nothing changes.
    if let files = try? FileManager.default.contentsOfDirectory(
      at: modeDirectory, includingPropertiesForKeys: nil)
    {
      for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
      where ["txt", "csv", "tsv"].contains(file.pathExtension) {
        if let dictionary = try? TextDictionary.load(contentsOf: file) {
          index.addText(dictionary, name: file.lastPathComponent, priority: .mode)
        }
      }
    }

    if let loaded = try? TextDictionary.load(contentsOf: userDictionaryURL) {
      userDictionary = loaded
    }
    index.addText(userDictionary, name: InputSession.userLayerName, priority: .user)

    if let loaded = try? LearningStore.load(contentsOf: learningURL) {
      learning = loaded
      learning.compact()
    }
    index.addLearning(learning, name: InputSession.learnedLayerName)

    let bigramURL = dataDirectory.deletingLastPathComponent().appendingPathComponent("bigrams.tsv")
    let unigramURL = dataDirectory.deletingLastPathComponent().appendingPathComponent("counts.tsv")
    // Left off for the same reason the CLI leaves it off: the counting behind
    // it needs two different tokenisations that one pass cannot produce.
    _ = (bigramURL, unigramURL)
    bigrams = nil

    if let loaded = try? SegmentationStore.load(contentsOf: segmentationURL) {
      remembered = loaded
      remembered.compact()
    }

    refreshSummary()
  }

  // MARK: - Key handling

  enum Key {
    case character(Character)
    case space
    case commit
    case cancel
    case backspace
    case next
    case previous
    case pick(Int)
    case nextSegment
    case previousSegment
    case growSegment
    case shrinkSegment
  }

  /// Maps a raw key event onto the composition. Virtual key codes rather than
  /// characters, so backspace and escape arrive regardless of layout.
  func handle(_ event: NSEvent) -> Bool {
    // Ctrl+Delete forgets the selected candidate -- the key MS-IME uses to
    // drop an entry from the prediction list. Checked before plain Delete.
    if event.keyCode == NSEvent.Code.delete, event.modifierFlags.contains(.control) {
      return forgetSelection()
    }

    switch event.keyCode {
    case NSEvent.Code.space: return handle(.space)
    case NSEvent.Code.returnKey: return handle(.commit)
    case NSEvent.Code.escape: return handle(.cancel)
    case NSEvent.Code.delete: return handle(.backspace)
    // ←→ stay free: once segments exist they move between them, and Shift+←→
    // resizes the boundary. Candidates are ↑↓ and Space, as everywhere else.
    case NSEvent.Code.downArrow: return handle(.next)
    case NSEvent.Code.upArrow: return handle(.previous)
    case NSEvent.Code.rightArrow:
      return handle(event.modifierFlags.contains(.shift) ? .growSegment : .nextSegment)
    case NSEvent.Code.leftArrow:
      return handle(event.modifierFlags.contains(.shift) ? .shrinkSegment : .previousSegment)
    default: break
    }

    // Let ⌘-shortcuts through to the app.
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard modifiers.isSubset(of: [.shift]) else { return false }
    guard let characters = event.charactersIgnoringModifiers, characters.count == 1,
      let character = characters.first
    else { return false }

    if isSelecting, let digit = character.wholeNumberValue, (1...9).contains(digit) {
      return handle(.pick(digit - 1))
    }
    guard
      character.isLetter || character.isNumber || character.isPunctuation
        || character.isSymbol
    else { return false }
    return handle(.character(character))
  }

  func handle(_ key: Key) -> Bool {
    switch key {
    case .character(let character):
      guard !isSelecting else {
        // Typing while the candidate window is open commits what is on screen
        // first, the way every IME behaves.
        commitComposition()
        return handle(.character(character))
      }
      romajiPending.append(character)
      let (produced, pending) = Romaji.convert(romajiPending)
      kana += produced
      romajiPending = pending
      refreshCandidates()
      return true

    case .space:
      guard !kana.isEmpty || !romajiPending.isEmpty else { return false }
      flushPending()
      if isSelecting {
        composition.selectNextCandidate()
        syncFromComposition()
      } else {
        // First Space splits the reading. Everything after this acts on
        // segments rather than on one flat list.
        composition = Composition(
          reading: kana, segmenter: segmenter, index: index, remembered: remembered)
        isSelecting = !composition.isEmpty
        syncFromComposition()
      }
      return true

    case .commit:
      guard !kana.isEmpty || !romajiPending.isEmpty else { return false }
      flushPending()
      if isSelecting, !composition.isEmpty {
        commitComposition()
      } else {
        committed += kana
        resetComposition()
      }
      return true

    case .cancel:
      if isSelecting {
        isSelecting = false
        composition = Composition()
        refreshCandidates()
      } else if !kana.isEmpty || !romajiPending.isEmpty {
        resetComposition()
      } else {
        return false
      }
      return true

    case .backspace:
      if isSelecting {
        isSelecting = false
        composition = Composition()
        refreshCandidates()
        return true
      }
      if !romajiPending.isEmpty {
        romajiPending.removeLast()
      } else if !kana.isEmpty {
        kana.removeLast()
      } else if !committed.isEmpty {
        committed.removeLast()
        return true
      } else {
        return false
      }
      refreshCandidates()
      return true

    case .next:
      guard isSelecting else { return false }
      composition.selectNextCandidate()
      syncFromComposition()
      return true

    case .previous:
      guard isSelecting else { return false }
      composition.selectPreviousCandidate()
      syncFromComposition()
      return true

    case .pick(let number):
      guard isSelecting, composition.selectCandidate(number) else { return false }
      syncFromComposition()
      commitComposition()
      return true

    case .nextSegment:
      guard isSelecting, composition.moveToNextSegment() else { return false }
      syncFromComposition()
      return true

    case .previousSegment:
      guard isSelecting, composition.moveToPreviousSegment() else { return false }
      syncFromComposition()
      return true

    case .growSegment, .shrinkSegment:
      guard isSelecting else { return false }
      let delta = key.isGrow ? 1 : -1
      guard composition.resizeActiveSegment(by: delta, index: index) else { return false }
      composition.resplitTail(segmenter: segmenter, index: index)
      syncFromComposition()
      return true
    }
  }

  private func flushPending() {
    guard !romajiPending.isEmpty else { return }
    // Trailing "n" is the common case: なn -> なん.
    let (produced, pending) = Romaji.convert(romajiPending + "'")
    kana += produced
    romajiPending = pending == "'" ? "" : pending
  }

  /// Commits every segment, and teaches each one separately.
  ///
  /// Per segment rather than per sentence: what the user confirmed is that
  /// this reading maps to this word, and that is the claim worth remembering.
  private func commitComposition() {
    // The split the user looked at and accepted, kept whole. Next time this
    // reading appears it is recalled rather than recomputed — the same move as
    // expanding inflections at build time, applied to joins.
    if learnOnCommit, composition.segments.count >= 2 {
      remembered.record(
        segments: composition.segments.map {
          SegmentationStore.Segment(reading: $0.chosenReading, surface: $0.surface)
        })
      persistSegmentations()
    }
    for segment in composition.segments {
      committed += segment.surface
      guard learnOnCommit, segment.candidates.indices.contains(segment.selection) else { continue }
      let candidate = segment.candidates[segment.selection]
      if candidate.priority != .user {
        learn(reading: segment.chosenReading, surface: segment.surface)
      }
    }
    resetComposition()
  }

  /// Mirrors the active segment onto the flat candidate list the UI reads.
  private func syncFromComposition() {
    candidates = composition.activeCandidates
    selection = composition.activeSelection
  }

  private func resetComposition() {
    kana = ""
    romajiPending = ""
    candidates = []
    selection = 0
    isSelecting = false
    composition = Composition()
  }

  // MARK: - Lookup

  private func refreshCandidates() {
    guard !kana.isEmpty else {
      candidates = []
      isSelecting = false
      return
    }
    let started = DispatchTime.now().uptimeNanoseconds
    var found = index.candidates(
      for: kana, limit: 20, predictionKeys: predictionEnabled ? 8 : 0)
    lastLookupMicroseconds = Int((DispatchTime.now().uptimeNanoseconds - started) / 1000)

    // An IME always lets you commit what you typed. Without this the candidate
    // list is simply empty the moment the reading crosses a word boundary --
    // which, with no lattice, is most of the time.
    for fallback in [kana, Kana.toKatakana(kana)]
    where !found.contains(where: { $0.surface == fallback }) {
      found.append(
        LayeredIndex.Candidate(
          surface: fallback, reading: kana, priority: .baseline, layerName: "kana", cost: 0,
          isExact: true))
    }

    candidates = found
    if selection >= candidates.count { selection = 0 }
  }

  // MARK: - Learning and the user dictionary

  /// Committing teaches the decaying layer, not the permanent one. What the
  /// user typed on purpose and what they happened to confirm once are
  /// different claims, and only the first should be permanent.
  func learn(reading: String, surface: String) {
    learning.record(reading: reading, surface: surface)
    index.replaceLearning(learning, name: InputSession.learnedLayerName)
    persistLearning()
    refreshSummary()
  }

  /// Undo for learning. Even with decay, a wrong commit sits on top for a
  /// month; ⌃Delete takes it back immediately.
  ///
  /// Forgetting is deliberately coarse -- the surface goes wherever it appears
  /// under that reading. Being asked to forget a candidate and then seeing it
  /// again is worse than forgetting a little too much.
  @discardableResult
  func forgetSelection() -> Bool {
    guard candidates.indices.contains(selection) else { return false }
    let candidate = candidates[selection]
    switch candidate.priority {
    case .learned:
      learning.forget(surface: candidate.surface, reading: candidate.reading)
      index.replaceLearning(learning, name: InputSession.learnedLayerName)
      persistLearning()
    case .user:
      userDictionary.remove(reading: candidate.reading, surface: candidate.surface)
      index.replaceText(userDictionary, name: InputSession.userLayerName)
      persistUserDictionary()
    default:
      status = "\(candidate.surface) came from \(candidate.layerName); nothing to forget"
      return true
    }
    refreshSummary()
    status = "forgot \(candidate.reading) → \(candidate.surface)"
    refreshCandidates()
    if selection >= candidates.count { selection = max(candidates.count - 1, 0) }
    return true
  }

  func forgetEverything() {
    learning.removeAll()
    remembered.removeAll()
    persistSegmentations()
    index.replaceLearning(learning, name: InputSession.learnedLayerName)
    persistLearning()
    refreshSummary()
    status = "cleared what was learned; the user dictionary is untouched"
    refreshCandidates()
  }

  func addUserWord(reading: String, surface: String) {
    let reading = reading.trimmingCharacters(in: .whitespaces)
    let surface = surface.trimmingCharacters(in: .whitespaces)
    guard !reading.isEmpty, !surface.isEmpty else {
      status = "reading and surface are both required"
      return
    }
    userDictionary.add(reading: reading, surface: surface)
    index.replaceText(userDictionary, name: InputSession.userLayerName)
    persistUserDictionary()
    refreshSummary()
    status = "added \(reading) → \(surface) to the user layer"
    refreshCandidates()
  }

  private func persistSegmentations() {
    do {
      try FileManager.default.createDirectory(
        at: segmentationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try remembered.serialized().write(to: segmentationURL, atomically: true, encoding: .utf8)
    } catch {
      status = "could not save segmentations: \(error.localizedDescription)"
    }
  }

  private func persistLearning() {
    guard learnOnCommit else { return }
    do {
      try FileManager.default.createDirectory(
        at: learningURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try learning.serialized().write(to: learningURL, atomically: true, encoding: .utf8)
    } catch {
      status = "could not save what was learned: \(error.localizedDescription)"
    }
  }

  private func persistUserDictionary() {
    do {
      try FileManager.default.createDirectory(
        at: userDictionaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try userDictionary.serialized().write(
        to: userDictionaryURL, atomically: true, encoding: .utf8)
    } catch {
      status = "could not save the user dictionary: \(error.localizedDescription)"
    }
  }

  private func refreshSummary() {
    layerSummary = index.layerSummary
    userDictionaryEntries = userDictionary.entryCount
    learnedEntries = learning.entryCount
    rememberedSegmentations = remembered.count
  }

  var userDictionaryPath: String { userDictionaryURL.path }
  var learningPath: String { learningURL.path }

  func clearCommitted() {
    committed = ""
  }
}

extension InputSession.Key {
  var isGrow: Bool {
    if case .growSegment = self { return true }
    return false
  }
}
