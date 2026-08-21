import XCTest

@testable import KanaKanjiCore

final class SegmentationStoreTests: XCTestCase {
  private func segment(_ reading: String, _ surface: String) -> SegmentationStore.Segment {
    SegmentationStore.Segment(reading: reading, surface: surface)
  }

  /// The whole idea: a join that was confirmed once is recalled rather than
  /// recomputed, so no model of how words join is needed.
  func testRecallsAConfirmedSplit() {
    var store = SegmentationStore()
    store.record(
      segments: [segment("きょう", "今日"), segment("は", "は"), segment("あつかった", "暑かった")],
      today: 0)

    let recalled = store.segments(for: "きょうはあつかった", today: 0)
    XCTAssertEqual(recalled?.map(\.surface), ["今日", "は", "暑かった"])
  }

  /// Yesterday's きょうは carries into today's きょうはさむかった. The openings
  /// repeat even when the sentences do not, and that is where the value is.
  func testRecallsTheLongestRememberedOpening() {
    var store = SegmentationStore()
    store.record(segments: [segment("きょう", "今日"), segment("は", "は")], today: 0)
    store.record(
      segments: [segment("きょう", "今日"), segment("は", "は"), segment("あめ", "雨")], today: 0)

    let prefix = store.longestPrefix(of: "きょうはあめがふる", today: 0)
    XCTAssertEqual(prefix?.matched, "きょうはあめ")
    XCTAssertEqual(prefix?.segments.map(\.surface), ["今日", "は", "雨"])
  }

  func testPrefixIgnoresUnrelatedReadings() {
    var store = SegmentationStore()
    store.record(segments: [segment("あした", "明日"), segment("の", "の")], today: 0)
    XCTAssertNil(store.longestPrefix(of: "きょうはさむい", today: 0))
  }

  /// A single segment is a word, and the word layers already hold it. What is
  /// worth storing here is where the joins went.
  func testSingleSegmentsAreNotRemembered() {
    var store = SegmentationStore()
    store.record(segments: [segment("きょう", "今日")], today: 0)
    XCTAssertEqual(store.count, 0)
  }

  /// Correcting a split replaces it. Keeping the old answer around to compete
  /// would undo the correction.
  func testACorrectionReplacesTheOldSplit() {
    var store = SegmentationStore()
    store.record(segments: [segment("きょうは", "教派"), segment("あつかった", "暑かった")], today: 0)
    store.record(
      segments: [segment("きょう", "今日"), segment("は", "は"), segment("あつかった", "暑かった")],
      today: 0)
    XCTAssertEqual(
      store.segments(for: "きょうはあつかった", today: 0)?.map(\.surface),
      ["今日", "は", "暑かった"])
  }

  func testDecaysLikeTheWordLayer() {
    var store = SegmentationStore()
    store.record(segments: [segment("きょう", "今日"), segment("は", "は")], today: 0)
    XCTAssertNotNil(store.segments(for: "きょうは", today: 31))
    XCTAssertNil(store.segments(for: "きょうは", today: 32))
  }

  func testRoundTrip() {
    var store = SegmentationStore()
    for _ in 0..<4 {
      store.record(segments: [segment("きょう", "今日"), segment("は", "は")], today: 500)
    }
    let reparsed = SegmentationStore.parse(store.serialized())
    XCTAssertEqual(reparsed.segments(for: "きょうは", today: 500)?.map(\.surface), ["今日", "は"])
    XCTAssertNotNil(reparsed.segments(for: "きょうは", today: 563))
  }

  /// Surfaces may contain "/" (and/or, 24/7); readings never do.
  func testSurfacesWithSlashesSurviveSerialisation() {
    var store = SegmentationStore()
    store.record(segments: [segment("にじゅうよん", "24/7"), segment("じかん", "時間")], today: 0)
    let reparsed = SegmentationStore.parse(store.serialized())
    XCTAssertEqual(
      reparsed.segments(for: "にじゅうよんじかん", today: 0)?.map(\.surface), ["24/7", "時間"])
  }
}
