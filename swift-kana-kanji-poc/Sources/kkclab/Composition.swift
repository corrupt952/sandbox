import Foundation
import KanaKanjiCore

/// A reading split into segments, each with its own candidate list.
///
/// This is where the engine stops being a function and starts being an input
/// method. Conversion produces one guess; what makes it usable is being able
/// to disagree with it — move to the segment that is wrong, pick a different
/// word, or tell it the boundary is in the wrong place.
///
/// Boundaries are the hard half. Measured, dropping parts of speech costs
/// almost nothing in conversion accuracy but halves boundary precision, which
/// means this engine will put the split in the wrong place more often than a
/// POS-based one. Resizing is not a luxury feature here — it is how the user
/// pays for the part the model gave up.
struct Composition {
  struct Segment {
    var reading: String
    var candidates: [LayeredIndex.Candidate]
    var selection: Int

    var surface: String {
      candidates.indices.contains(selection) ? candidates[selection].surface : reading
    }

    /// The reading of what was actually chosen, which is not always the
    /// reading of the segment.
    ///
    /// A prediction covers more than was typed: choosing
    /// クロスサイトスクリプティング after typing くろす commits a word whose
    /// reading is くろすさいとすくりぷてぃんぐ. Learning the segment's reading
    /// instead would record くろす → クロスサイトスクリプティング, which is
    /// simply false, and would then be recalled forever.
    var chosenReading: String {
      candidates.indices.contains(selection) ? candidates[selection].reading : reading
    }
  }

  private(set) var segments: [Segment] = []
  private(set) var active = 0

  var isEmpty: Bool { segments.isEmpty }
  var reading: String { segments.map(\.reading).joined() }
  var text: String { segments.map(\.surface).joined() }

  /// Characters of the whole reading, for boundary arithmetic.
  private var characters: [Character] = []

  // MARK: - Building

  init() {}

  /// A remembered split wins over a computed one, and a remembered opening
  /// wins over the opening the segmenter would have chosen.
  ///
  /// Recall first is the whole point: a split the user looked at and accepted
  /// is better evidence than anything a cost function produces, and it costs a
  /// dictionary lookup rather than a search.
  init(
    reading: String, segmenter: SegmentingConverter, index: LayeredIndex,
    remembered: SegmentationStore = SegmentationStore()
  ) {
    characters = Array(Kana.toHiragana(reading))
    guard !characters.isEmpty else { return }
    let normalized = String(characters)

    if let recalled = remembered.segments(for: normalized) {
      segments = Composition.build(recalled, index: index)
      return
    }

    // A remembered opening, then the segmenter for whatever follows.
    if let prefix = remembered.longestPrefix(of: normalized), prefix.matched != normalized {
      var built = Composition.build(prefix.segments, index: index)
      let tail = String(normalized.dropFirst(prefix.matched.count))
      built += Composition.build(
        characters: Array(tail), lengths: Composition.split(tail, segmenter: segmenter),
        index: index)
      segments = built
      return
    }

    segments = Composition.build(
      characters: characters, lengths: Composition.split(normalized, segmenter: segmenter),
      index: index)
  }

  private static func split(_ reading: String, segmenter: SegmentingConverter) -> [Int] {
    guard let best = segmenter.convert(reading, count: 1).first, !best.segments.isEmpty else {
      return [reading.count]
    }
    return best.segments.map { $0.reading.count }
  }

  /// Builds from a remembered split, putting the remembered surface first so
  /// the recalled choice is what shows.
  private static func build(_ recalled: [SegmentationStore.Segment], index: LayeredIndex)
    -> [Segment]
  {
    recalled.map { remembered in
      var built = segment(remembered.reading, index: index)
      if let position = built.candidates.firstIndex(where: { $0.surface == remembered.surface }) {
        built.selection = position
      } else {
        // The remembered surface is no longer in the dictionary — a mode
        // dictionary was removed, say. Keep it anyway: the user chose it.
        built.candidates.insert(
          LayeredIndex.Candidate(
            surface: remembered.surface, reading: remembered.reading, priority: .learned,
            layerName: "remembered", cost: 0, isExact: true), at: 0)
        built.selection = 0
      }
      return built
    }
  }

  private static func build(characters: [Character], lengths: [Int], index: LayeredIndex)
    -> [Segment]
  {
    var segments: [Segment] = []
    var start = 0
    for length in lengths {
      let end = min(start + length, characters.count)
      guard start < end else { break }
      segments.append(
        segment(String(characters[start..<end]), index: index, final: end == characters.count))
      start = end
    }
    if start < characters.count {
      segments.append(segment(String(characters[start...]), index: index, final: true))
    }
    return segments
  }

  /// - Parameter final: the last segment keeps its predictions.
  ///
  /// Conversion normally drops them, and for an interior segment that is
  /// right: its reading is fixed by the segments after it, so a longer one
  /// cannot apply. The last segment is different — more could still follow.
  /// Dropping them there threw away the candidate the user was typing towards:
  /// くろす showed クロスサイトスクリプティング and XSS while typing, and
  /// pressing Space replaced them with 聖衣 and 黒須. The detour this is meant
  /// to remove reappeared at the moment of converting.
  private static func segment(_ reading: String, index: LayeredIndex, final: Bool = false)
    -> Segment
  {
    Segment(
      reading: reading,
      candidates: index.candidates(
        for: reading, limit: 20, predictionKeys: final ? 8 : 0),
      selection: 0)
  }

  // MARK: - Moving

  mutating func moveToNextSegment() -> Bool {
    guard active + 1 < segments.count else { return false }
    active += 1
    return true
  }

  mutating func moveToPreviousSegment() -> Bool {
    guard active > 0 else { return false }
    active -= 1
    return true
  }

  mutating func selectNextCandidate() {
    guard segments.indices.contains(active), !segments[active].candidates.isEmpty else { return }
    let count = segments[active].candidates.count
    segments[active].selection = (segments[active].selection + 1) % count
  }

  mutating func selectPreviousCandidate() {
    guard segments.indices.contains(active), !segments[active].candidates.isEmpty else { return }
    let count = segments[active].candidates.count
    segments[active].selection = (segments[active].selection + count - 1) % count
  }

  mutating func selectCandidate(_ position: Int) -> Bool {
    guard segments.indices.contains(active),
      segments[active].candidates.indices.contains(position)
    else { return false }
    segments[active].selection = position
    return true
  }

  var activeCandidates: [LayeredIndex.Candidate] {
    segments.indices.contains(active) ? segments[active].candidates : []
  }

  var activeSelection: Int {
    segments.indices.contains(active) ? segments[active].selection : 0
  }

  // MARK: - Resizing

  /// Grows or shrinks the active segment, re-splitting everything after it.
  ///
  /// Only the tail is rebuilt: segments before the active one are choices the
  /// user has already made or accepted, and moving a boundary is not a reason
  /// to throw them away.
  mutating func resizeActiveSegment(by delta: Int, index: LayeredIndex) -> Bool {
    guard segments.indices.contains(active) else { return false }

    let head = segments.prefix(active)
    let consumed = head.reduce(0) { $0 + $1.reading.count }
    let available = characters.count - consumed
    let current = segments[active].reading.count
    let length = current + delta
    guard length >= 1, length <= available, length != current else { return false }

    let tailStart = consumed + length
    var rebuilt = Array(head)
    rebuilt.append(
      Composition.segment(
        String(characters[consumed..<tailStart]), index: index,
        final: tailStart == characters.count))
    if tailStart < characters.count {
      // The remainder is re-split from scratch: after moving a boundary the
      // old split of the tail describes a reading that no longer starts there.
      rebuilt.append(
        Composition.segment(String(characters[tailStart...]), index: index, final: true))
    }
    segments = rebuilt
    return true
  }

  /// Re-splits the tail with the segmenter after a resize, so the remainder
  /// does not stay as one undifferentiated lump.
  mutating func resplitTail(segmenter: SegmentingConverter, index: LayeredIndex) {
    guard segments.count > active + 1 else { return }
    let tail = segments[(active + 1)...].map(\.reading).joined()
    guard !tail.isEmpty else { return }
    let lengths =
      segmenter.convert(tail, count: 1).first.map { $0.segments.map { $0.reading.count } }
      ?? [tail.count]
    var rebuilt = Array(segments.prefix(active + 1))
    rebuilt += Composition.build(characters: Array(tail), lengths: lengths, index: index)
    segments = rebuilt
  }
}
