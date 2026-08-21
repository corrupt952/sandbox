import XCTest

@testable import KanaKanjiCore

final class RomajiTests: XCTestCase {
  func testBasicMora() {
    XCTAssertEqual(Romaji.convert("kyou").kana, "きょう")
    XCTAssertEqual(Romaji.convert("watashi").kana, "わたし")
    XCTAssertEqual(Romaji.convert("tsuki").kana, "つき")
  }

  func testSokuon() {
    XCTAssertEqual(Romaji.convert("gakkou").kana, "がっこう")
    XCTAssertEqual(Romaji.convert("kitte").kana, "きって")
  }

  func testSyllabicN() {
    XCTAssertEqual(Romaji.convert("kanji").kana, "かんじ")
    XCTAssertEqual(Romaji.convert("honnda").kana, "ほんだ")
    // n before a vowel is still ambiguous: な could be coming.
    let partial = Romaji.convert("kan")
    XCTAssertEqual(partial.kana, "か")
    XCTAssertEqual(partial.pending, "n")
    // ny- must not become ん.
    XCTAssertEqual(Romaji.convert("konnyaku").kana, "こんにゃく")
  }

  func testPendingTail() {
    let partial = Romaji.convert("ky")
    XCTAssertEqual(partial.kana, "")
    XCTAssertEqual(partial.pending, "ky")
    XCTAssertEqual(Romaji.convert("kyo").kana, "きょ")
  }

  func testPunctuation() {
    XCTAssertEqual(Romaji.convert("ka-").kana, "かー")
    XCTAssertEqual(Romaji.convert("a.").kana, "あ。")
  }
}

final class InflectionTests: XCTestCase {
  private func readings(_ form: String, _ type: String, _ stem: String) -> [String] {
    Inflection.suffixes(form: form, type: type, stemReading: stem).map(\.reading)
  }

  func testGodanTakesPastFromTaStem() {
    // 書い (五段・カ行イ音便, 連用タ接続) + た
    XCTAssertTrue(readings("連用タ接続", "五段・カ行イ音便", "かい").contains("た"))

    // 書き (五段, 連用形) must NOT take た, or the index grows 書きた.
    let renyou = readings("連用形", "五段動詞", "かき")
    XCTAssertFalse(renyou.contains("た"))
    XCTAssertTrue(renyou.contains("ます"))
  }

  func testIchidanTakesPastFromRenyou() {
    // 食べ (一段, 連用形) + た
    let suffixes = readings("連用形", "一段", "たべ")
    XCTAssertTrue(suffixes.contains("た"))
    XCTAssertTrue(suffixes.contains("ます"))
  }

  /// 撥音便 and ガ行 voice the suffix: 読ん+だ, 泳い+だ. Getting this wrong
  /// produced 読んた and lost 読んだ entirely.
  func testEuphonicVoicing() {
    let yon = readings("連用タ接続", "五段動詞", "よん")
    XCTAssertTrue(yon.contains("だ"))
    XCTAssertTrue(yon.contains("で"))
    XCTAssertFalse(yon.contains("た"))

    // ガ行: カ行イ音便 has its own label, so an い-final generic 五段 stem is ガ行.
    XCTAssertTrue(readings("連用タ接続", "五段動詞", "およい").contains("だ"))
    // カ行イ音便 stays unvoiced even though it also ends in い.
    XCTAssertTrue(readings("連用タ接続", "五段・カ行イ音便", "かい").contains("た"))
    XCTAssertFalse(readings("連用タ接続", "五段・カ行イ音便", "かい").contains("だ"))

    // 促音便 is unvoiced: 立っ+た.
    XCTAssertTrue(readings("連用タ接続", "五段動詞", "たっ").contains("た"))
  }

  /// サ行五段 has no 連用タ接続; 話し+た comes straight off 連用形.
  func testSaRowGodanTakesPastFromRenyou() {
    let hanashi = readings("連用形", "五段動詞", "はなし")
    XCTAssertTrue(hanashi.contains("た"))
    XCTAssertTrue(hanashi.contains("て"))
    XCTAssertTrue(hanashi.contains("ます"))

    // Other 五段 rows must stay excluded, or 書きた appears.
    XCTAssertFalse(readings("連用形", "五段動詞", "かき").contains("た"))
    XCTAssertFalse(readings("連用形", "五段動詞", "よみ").contains("た"))
  }

  func testSuruNouns() {
    let noun = Inflection.Feature(
      partOfSpeech: "名詞", subcategory: "サ変接続", conjugationType: "*", conjugationForm: "*")
    XCTAssertTrue(Inflection.isSuruNoun(noun))
    XCTAssertTrue(Inflection.isInflectable(noun))
    XCTAssertTrue(Inflection.suruSuffixes.map(\.reading).contains("する"))
    XCTAssertTrue(Inflection.suruSuffixes.map(\.reading).contains("しました"))

    let plain = Inflection.Feature(
      partOfSpeech: "名詞", subcategory: "一般", conjugationType: "*", conjugationForm: "*")
    XCTAssertFalse(Inflection.isSuruNoun(plain))
    XCTAssertFalse(Inflection.isInflectable(plain))
  }

  func testStemsAreHidden() {
    // 書い on its own is not a word anyone typed.
    XCTAssertTrue(Inflection.isStemOnly(form: "連用タ接続"))
    XCTAssertTrue(Inflection.isStemOnly(form: "未然形"))
    // 基本形 and 連用形 are usable as they stand.
    XCTAssertFalse(Inflection.isStemOnly(form: "基本形"))
    XCTAssertFalse(Inflection.isStemOnly(form: "連用形"))
  }

  func testOnlyVerbsAdjectivesAndSuruNounsInflect() {
    func feature(_ pos: String, _ sub: String = "*") -> Inflection.Feature {
      Inflection.Feature(
        partOfSpeech: pos, subcategory: sub, conjugationType: "*", conjugationForm: "*")
    }
    XCTAssertTrue(Inflection.isInflectable(feature("動詞", "自立")))
    XCTAssertTrue(Inflection.isInflectable(feature("形容詞", "自立")))
    XCTAssertFalse(Inflection.isInflectable(feature("名詞", "一般")))
    XCTAssertFalse(Inflection.isInflectable(feature("助詞", "格助詞")))
  }

  func testParsesIdDef() {
    let features = Inflection.parseIdDef(
      """
      726 動詞,自立,*,*,五段・カ行イ音便,連用タ接続,*
      1841 名詞,サ変接続,*,*,*,*,*
      1923 名詞,固有名詞,人名,姓,*,*,*
      """)
    XCTAssertEqual(features[726]?.partOfSpeech, "動詞")
    XCTAssertEqual(features[726]?.conjugationType, "五段・カ行イ音便")
    XCTAssertEqual(features[726]?.conjugationForm, "連用タ接続")
    XCTAssertEqual(features[1841]?.subcategory, "サ変接続")
    XCTAssertEqual(features[1923]?.partOfSpeech, "名詞")
  }
}

final class TextDictionaryTests: XCTestCase {
  func testParsesMSIMEExport() {
    let dictionary = TextDictionary.parse(
      """
      !Microsoft IME Dictionary Tool
      えっくすえすえす\tXSS\t名詞
      くろすさいとすくりぷてぃんぐ\tXSS\t名詞
      """)
    XCTAssertEqual(dictionary.readingCount, 2)
    XCTAssertEqual(dictionary.entries(forReading: "えっくすえすえす").first?.surface, "XSS")
  }

  func testNormalisesKatakanaReadings() {
    let dictionary = TextDictionary.parse("エックスエスエス\tXSS\t名詞")
    XCTAssertEqual(dictionary.entries(forReading: "えっくすえすえす").first?.surface, "XSS")
  }

  func testPrefixSearch() {
    let dictionary = TextDictionary.parse(
      """
      かい\t貝\t名詞
      かいた\t書いた\t動詞
      かいたい\t解体\t名詞
      きた\t北\t名詞
      """)
    let found = dictionary.entries(withPrefix: "かい", maxKeys: 10).map(\.0)
    XCTAssertEqual(found, ["かい", "かいた", "かいたい"])
  }

  func testRoundTrip() {
    var dictionary = TextDictionary.parse("えっくすえすえす\tXSS\t名詞")
    dictionary.add(reading: "しーさーふ", surface: "CSRF")
    let reparsed = TextDictionary.parse(dictionary.serialized())
    XCTAssertEqual(reparsed.entries(forReading: "しーさーふ").first?.surface, "CSRF")
    XCTAssertEqual(reparsed.entryCount, 2)
  }
}

final class LearningStoreTests: XCTestCase {
  func testCountRisesWithUse() {
    var store = LearningStore()
    store.record(reading: "きょうは", surface: "教派", today: 100)
    store.record(reading: "きょうは", surface: "教派", today: 100)
    XCTAssertEqual(store.entries(forReading: "きょうは", today: 100).first?.count, 2)
  }

  /// The whole point of the layer: a mistake fades instead of being permanent.
  func testHalvesEveryThirtyTwoDays() {
    var store = LearningStore()
    for _ in 0..<8 { store.record(reading: "きょうは", surface: "教派", today: 0) }
    XCTAssertEqual(store.entries(forReading: "きょうは", today: 0).first?.count, 8)
    XCTAssertEqual(store.entries(forReading: "きょうは", today: 32).first?.count, 4)
    XCTAssertEqual(store.entries(forReading: "きょうは", today: 64).first?.count, 2)
    XCTAssertEqual(store.entries(forReading: "きょうは", today: 96).first?.count, 1)
  }

  /// A single confirmation buys exactly one half-life: 1 >> 1 is 0.
  /// This is what stops きょうは→教派 from being a life sentence.
  func testOneUseLastsOneHalfLife() {
    var store = LearningStore()
    store.record(reading: "きょうは", surface: "教派", today: 0)
    XCTAssertFalse(store.entries(forReading: "きょうは", today: 31).isEmpty)
    XCTAssertTrue(store.entries(forReading: "きょうは", today: 32).isEmpty)
  }

  /// The 128-day rule is a backstop for entries whose count would otherwise
  /// still be above zero.
  func testExpiresAfterFourMonthsRegardlessOfCount() {
    var store = LearningStore()
    for _ in 0..<200 { store.record(reading: "たべる", surface: "食べる", today: 0) }
    XCTAssertFalse(store.entries(forReading: "たべる", today: 127).isEmpty)
    XCTAssertTrue(store.entries(forReading: "たべる", today: 128).isEmpty)
  }

  func testMoreUsedRanksFirst() {
    var store = LearningStore()
    store.record(reading: "こうし", surface: "格子", today: 0)
    for _ in 0..<3 { store.record(reading: "こうし", surface: "講師", today: 0) }
    XCTAssertEqual(store.entries(forReading: "こうし", today: 0).map(\.surface), ["講師", "格子"])
  }

  /// Coarse on purpose: forgetting a candidate must not leave a twin behind.
  func testForgetIsCoarse() {
    var store = LearningStore()
    store.record(reading: "きょうは", surface: "教派", today: 0)
    store.record(reading: "きょう", surface: "教派", today: 0)
    store.forget(surface: "教派")
    XCTAssertTrue(store.entries(forReading: "きょうは", today: 0).isEmpty)
    XCTAssertTrue(store.entries(forReading: "きょう", today: 0).isEmpty)
  }

  func testRoundTripKeepsDecayState() {
    var store = LearningStore()
    for _ in 0..<4 { store.record(reading: "たべる", surface: "食べる", today: 500) }
    let reparsed = LearningStore.parse(store.serialized())
    XCTAssertEqual(reparsed.entries(forReading: "たべる", today: 500).first?.count, 4)
    XCTAssertEqual(reparsed.entries(forReading: "たべる", today: 532).first?.count, 2)
  }

  func testCompactDropsDeadEntries() {
    var store = LearningStore()
    store.record(reading: "きょうは", surface: "教派", today: 0)
    store.record(reading: "たべる", surface: "食べる", today: 200)
    store.compact(today: 200)
    XCTAssertEqual(store.readingCount, 1)
  }
}

final class LayeredIndexTests: XCTestCase {
  /// The claim the whole layer design rests on: a word in the user dictionary
  /// is the first candidate, always. Not "usually", not "if its cost wins".
  func testUserLayerAlwaysWins() {
    let index = LayeredIndex()
    index.addText(
      TextDictionary.parse("こうし\t講師\t名詞"), name: "baseline", priority: .baseline)
    index.addText(TextDictionary.parse("こうし\t子牛\t名詞"), name: "mode", priority: .mode)
    index.addText(TextDictionary.parse("こうし\t格子\t名詞"), name: "user", priority: .user)

    let candidates = index.candidates(for: "こうし")
    // Kana is appended last and never competes for rank.
    XCTAssertEqual(candidates.map(\.surface), ["格子", "子牛", "講師", "こうし", "コウシ"])
    XCTAssertEqual(candidates.first?.priority, .user)
  }

  /// Kana is derived from the reading, not looked up, so a candidate list is
  /// never empty and 結果 never has to outrank けっか to be chosen.
  func testKanaTailIsAlwaysAvailableAndLast() {
    let index = LayeredIndex()
    index.addText(TextDictionary.parse("けっか\t結果\t名詞"), name: "baseline", priority: .baseline)
    XCTAssertEqual(index.candidates(for: "けっか").map(\.surface), ["結果", "けっか", "ケッカ"])
    // Even with nothing in any dictionary.
    XCTAssertEqual(index.candidates(for: "ぬるぽ").map(\.surface), ["ぬるぽ", "ヌルポ"])
    XCTAssertTrue(index.candidates(for: "けっか", kanaTail: false).map(\.surface) == ["結果"])
  }

  func testExactMatchesPrecedePredictions() {
    let index = LayeredIndex()
    index.addText(TextDictionary.parse("かい\t貝\t名詞"), name: "baseline", priority: .baseline)
    index.addText(TextDictionary.parse("かいたい\t解体\t名詞"), name: "mode", priority: .mode)

    let candidates = index.candidates(for: "かい")
    XCTAssertEqual(candidates.first?.surface, "貝")
    XCTAssertTrue(candidates.first?.isExact == true)
    XCTAssertTrue(candidates.contains { $0.surface == "解体" && !$0.isExact })
  }

  /// The baseline never predicts. Ranking a million-entry lexicon by its own
  /// costs puts a useful guess in the window 11.9% of the time and fills the
  /// rest with のんで→ノンデイト; the same measurement on user history gives
  /// 39.5%. Prediction belongs to the layers that know this user.
  func testBaselineDoesNotPredict() {
    let index = LayeredIndex()
    index.addText(TextDictionary.parse("かいたい\t解体\t名詞"), name: "baseline", priority: .baseline)
    // Only the kana tail comes back — no 解体.
    XCTAssertEqual(index.candidates(for: "かい").map(\.surface), ["かい", "カイ"])

    index.addText(TextDictionary.parse("かいたい\t会いたい\t動詞"), name: "learned", priority: .learned)
    XCTAssertTrue(index.candidates(for: "かい").contains { $0.surface == "会いたい" })
  }

  func testPredictionCanBeDisabled() {
    let index = LayeredIndex()
    index.addText(TextDictionary.parse("かいたい\t解体\t名詞"), name: "mode", priority: .mode)
    XCTAssertFalse(
      index.candidates(for: "かい", predictionKeys: 8).contains { $0.isExact == false } == false)
    XCTAssertFalse(
      index.candidates(for: "かい", predictionKeys: 0).contains { $0.surface == "解体" })
  }

  func testKatakanaInputMatchesHiraganaKeys() {
    let index = LayeredIndex()
    index.addText(TextDictionary.parse("とうきょう\t東京\t名詞"), name: "baseline", priority: .baseline)
    XCTAssertEqual(index.candidates(for: "トウキョウ").first?.surface, "東京")
  }
}
