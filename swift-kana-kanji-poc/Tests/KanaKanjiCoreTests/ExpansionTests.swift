import XCTest

@testable import KanaKanjiCore

final class ExpansionTests: XCTestCase {
  /// The point of the whole exercise: XSS filed only under its full name is
  /// unreachable to anyone who types えっくすえすえす, which is what people
  /// type.
  func testAcronymsAreSpelledOut() {
    XCTAssertEqual(Expansion.spelledOut("XSS"), "えっくすえすえす")
    XCTAssertEqual(Expansion.spelledOut("CSRF"), "しーえすあーるえふ")
    XCTAssertEqual(Expansion.spelledOut("SAML"), "えすえーえむえる")
    // Case does not matter to the speaker.
    XCTAssertEqual(Expansion.spelledOut("xss"), "えっくすえすえす")
  }

  func testOnlyShortLatinRunsAreSpelledOut() {
    // Spelling out prose helps nobody.
    XCTAssertNil(Expansion.spelledOut("Burp Suite"))
    XCTAssertNil(Expansion.spelledOut("クロスサイトスクリプティング"))
    XCTAssertNil(Expansion.spelledOut("abcdefghij"))
    XCTAssertNotNil(Expansion.spelledOut("ISO27001"))
  }

  func testReadingsCombineGivenAndGenerated() {
    let readings = Expansion.readings(for: "XSS", given: ["くろすさいとすくりぷてぃんぐ"])
    XCTAssertEqual(readings.first, "くろすさいとすくりぷてぃんぐ")
    XCTAssertTrue(readings.contains("えっくすえすえす"))
    XCTAssertTrue(readings.contains("xss"))
  }

  func testKatakanaSurfaceIsReachableByItsOwnKana() {
    let readings = Expansion.readings(for: "ゼロトラスト", given: [])
    XCTAssertEqual(readings, ["ぜろとらすと"])
  }

  func testGivenReadingsAreNormalisedToHiragana() {
    let readings = Expansion.readings(for: "SIEM", given: ["シーム"])
    XCTAssertTrue(readings.contains("しーむ"))
  }

  /// The failure that hides. A kanji surface with no reading written down
  /// produces nothing at all — the row is in the file and the word is simply
  /// unreachable. 証明書失効リスト sat in the dictionary that way.
  func testKanjiWithoutReadingIsReportedUnreachable() {
    let result = Expansion.expand([
      Expansion.Entry(surface: "証明書失効リスト", given: [], partOfSpeech: "名詞")
    ])
    XCTAssertEqual(result.readings, 0)
    XCTAssertEqual(result.unreachable, ["証明書失効リスト"])
  }

  func testShortReadingsAreDroppedAtTheFloor() {
    let entry = Expansion.Entry(surface: "SIEM", given: ["しーむ"], partOfSpeech: "名詞")
    XCTAssertTrue(Expansion.expand([entry], minimumReadingLength: 3).dropped.isEmpty)
    XCTAssertFalse(Expansion.expand([entry], minimumReadingLength: 4).dropped.isEmpty)
  }

  func testParsesSource() {
    let entries = Expansion.parseSource(
      """
      # comment
      XSS\tくろすさいとすくりぷてぃんぐ
      OAuth\tおーおーす|おーす\t名詞
      ゼロトラスト
      """)
    XCTAssertEqual(entries.count, 3)
    XCTAssertEqual(entries[0].surface, "XSS")
    XCTAssertEqual(entries[1].given, ["おーおーす", "おーす"])
    XCTAssertEqual(entries[2].given, [])
    XCTAssertEqual(entries[2].partOfSpeech, "名詞")
  }

  func testEmitsMSIMERows() {
    let result = Expansion.expand([
      Expansion.Entry(surface: "XSS", given: ["くろすさいとすくりぷてぃんぐ"], partOfSpeech: "名詞")
    ])
    XCTAssertEqual(result.lines.first, "!Microsoft IME Dictionary Tool")
    XCTAssertTrue(result.lines.contains("えっくすえすえす\tXSS\t名詞"))
    // Round-trips through the dictionary the index actually loads.
    let dictionary = TextDictionary.parse(result.lines.joined(separator: "\n"))
    XCTAssertEqual(dictionary.entries(forReading: "えっくすえすえす").first?.surface, "XSS")
  }
}
