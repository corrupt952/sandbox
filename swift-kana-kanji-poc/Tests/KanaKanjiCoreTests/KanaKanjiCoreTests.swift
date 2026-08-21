import XCTest

@testable import KanaKanjiCore

final class KanaTests: XCTestCase {
  func testKatakanaBecomesHiragana() {
    XCTAssertEqual(Kana.toHiragana("トウキョウ"), "とうきょう")
    XCTAssertEqual(Kana.toHiragana("ガッコウ"), "がっこう")
  }

  func testProlongedMarkAndNonKanaSurvive() {
    XCTAssertEqual(Kana.toHiragana("コーヒー"), "こーひー")
    XCTAssertEqual(Kana.toHiragana("A1あ"), "A1あ")
  }

  func testIsAllKana() {
    XCTAssertTrue(Kana.isAllKana("あいうえお"))
    XCTAssertTrue(Kana.isAllKana("コーヒー"))
    XCTAssertFalse(Kana.isAllKana("東京"))
    XCTAssertFalse(Kana.isAllKana(""))
  }
}

final class SourceParsingTests: XCTestCase {
  func testSplitsPlainRow() {
    let fields = SourceParsing.splitCSV("東京,1288,1288,4569,名詞,固有名詞,地域,一般,*,*,東京,トウキョウ,トーキョー")
    XCTAssertEqual(fields.count, 13)
    XCTAssertEqual(fields[0], "東京")
    XCTAssertEqual(fields[3], "4569")
    XCTAssertEqual(fields[11], "トウキョウ")
  }

  func testSplitsQuotedField() {
    // ipadic itself never quotes, but the MeCab CSV format allows it and other
    // lexicons (naist-jdic, neologd) do use it for entries containing a comma.
    let fields = SourceParsing.splitCSV("\",\",1,1,0,記号,読点,*,*,*,*,\"a\"\"b\",、")
    XCTAssertEqual(fields[0], ",")
    XCTAssertEqual(fields[1], "1")
    XCTAssertEqual(fields[10], "a\"b")
    XCTAssertEqual(fields[11], "、")
  }

  func testParsesCharDef() throws {
    let text = """
      # comment
      DEFAULT	0 1 0
      HIRAGANA 0 1 2
      KATAKANA 1 1 2

      0x3041..0x309F  HIRAGANA
      0x30A1..0x30FF  KATAKANA
      """
    let property = try SourceParsing.parseCharDef(text)
    XCTAssertEqual(property.category(of: "あ".unicodeScalars.first!).name, "HIRAGANA")
    XCTAssertEqual(property.category(of: "ア".unicodeScalars.first!).length, 2)
    XCTAssertTrue(property.category(of: "ア".unicodeScalars.first!).invoke)
    XCTAssertFalse(property.category(of: "あ".unicodeScalars.first!).invoke)
    // Unmapped code points fall back to DEFAULT.
    XCTAssertEqual(property.category(of: "漢".unicodeScalars.first!).name, "DEFAULT")
  }

  func testParsesUnkDef() {
    let templates = SourceParsing.parseUnkDef("KATAKANA,1285,1285,8590,名詞,一般,*,*,*,*,*")
    XCTAssertEqual(templates["KATAKANA"]?.count, 1)
    XCTAssertEqual(templates["KATAKANA"]?.first?.cost, 8590)
  }
}

final class LatticeTests: XCTestCase {
  /// Two context IDs: 0 (BOS/EOS) and 1. Joining 1 -> 1 is expensive, so the
  /// search should prefer the single long word over two short ones unless the
  /// word costs say otherwise.
  private func makeMatrix(joinCost: Int16) -> ConnectionMatrix {
    ConnectionMatrix(leftSize: 2, rightSize: 2, costs: [0, 0, 0, joinCost])
  }

  private func node(_ surface: String, _ start: Int, _ end: Int, cost: Int32) -> LatticeNode {
    LatticeNode(
      surface: surface, reading: surface, start: start, end: end, leftId: 1, rightId: 1,
      wordCost: cost, isUnknown: false)
  }

  func testPicksCheapestPath() {
    var lattice = Lattice(inputLength: 2)
    lattice.insert(node("長", 0, 2, cost: 100))
    lattice.insert(node("短1", 0, 1, cost: 10))
    lattice.insert(node("短2", 1, 2, cost: 10))

    let cheapJoin = lattice.search(matrix: makeMatrix(joinCost: 0), count: 3)
    XCTAssertEqual(cheapJoin.first?.text, "短1短2")
    XCTAssertEqual(cheapJoin.first?.cost, 20)

    var expensive = Lattice(inputLength: 2)
    expensive.insert(node("長", 0, 2, cost: 100))
    expensive.insert(node("短1", 0, 1, cost: 10))
    expensive.insert(node("短2", 1, 2, cost: 10))
    let costlyJoin = expensive.search(matrix: makeMatrix(joinCost: 500), count: 3)
    XCTAssertEqual(costlyJoin.first?.text, "長")
    XCTAssertEqual(costlyJoin.first?.cost, 100)
  }

  func testReturnsRankedCandidates() {
    var lattice = Lattice(inputLength: 1)
    lattice.insert(node("三", 0, 1, cost: 30))
    lattice.insert(node("一", 0, 1, cost: 10))
    lattice.insert(node("二", 0, 1, cost: 20))

    let candidates = lattice.search(matrix: makeMatrix(joinCost: 0), count: 2)
    XCTAssertEqual(candidates.map(\.text), ["一", "二"])
    XCTAssertEqual(candidates.map(\.cost), [10, 20])
  }

  func testDetectsDisconnectedLattice() {
    var lattice = Lattice(inputLength: 3)
    lattice.insert(node("あ", 0, 1, cost: 1))
    // Nothing covers position 1..2, so the end is unreachable.
    XCTAssertFalse(lattice.isConnected)
    lattice.insert(node("いう", 1, 3, cost: 1))
    XCTAssertTrue(lattice.isConnected)
  }

  func testSegmentsAreOrderedLeftToRight() {
    var lattice = Lattice(inputLength: 3)
    lattice.insert(node("A", 0, 1, cost: 1))
    lattice.insert(node("B", 1, 2, cost: 1))
    lattice.insert(node("C", 2, 3, cost: 1))
    let candidate = lattice.search(matrix: makeMatrix(joinCost: 0), count: 1).first
    XCTAssertEqual(candidate?.segments.map(\.surface), ["A", "B", "C"])
  }
}

final class BinaryFormatTests: XCTestCase {
  func testRoundTripsLittleEndianValues() {
    var bytes: [UInt8] = []
    LE.append(UInt32(0x1234_5678), to: &bytes)
    LE.append(UInt16(0xBEEF), to: &bytes)
    LE.append(Int16(-1234), to: &bytes)

    bytes.withUnsafeBytes { buffer in
      XCTAssertEqual(LE.u32(buffer, 0), 0x1234_5678)
      XCTAssertEqual(LE.u16(buffer, 4), 0xBEEF)
      XCTAssertEqual(LE.i16(buffer, 6), -1234)
    }
  }

  func testCompareBytesOrdersLikeUTF8() {
    XCTAssertEqual(compareBytes(Array("あ".utf8), Array("い".utf8)), -1)
    XCTAssertEqual(compareBytes(Array("あ".utf8), Array("あ".utf8)), 0)
    XCTAssertEqual(compareBytes(Array("あい".utf8), Array("あ".utf8)), 1)
  }
}
