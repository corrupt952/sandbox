import Foundation

/// Build-time inflection expansion.
///
/// mozc stores stems, not inflected words: `かい → 書い` tagged
/// 五段・カ行イ音便/連用タ接続, with the た supplied by a separate auxiliary
/// entry that the lattice joins on. An index layer has no lattice, so without
/// this step `かいた` returns place names and no verb at all.
///
/// Expanding at build time is the whole bet: the work happens once, the
/// runtime stays a plain lookup, and which readings reach a word is written
/// down in the dictionary rather than decided by a model. The table below is
/// that written-down part -- it is meant to be read and argued with.
public enum Inflection {
  public struct Suffix {
    public var reading: String
    public var surface: String
  }

  private static func s(_ reading: String, _ surface: String) -> Suffix {
    Suffix(reading: reading, surface: surface)
  }

  /// Stems that are not words on their own. They stay out of the index; only
  /// their expansions go in. 書い alone is never something anyone typed.
  private static let stemOnlyForms: Set<String> = [
    "連用タ接続", "未然形", "未然ウ接続", "未然特殊", "未然ヌ接続", "未然レル接続",
    "仮定形", "仮定縮約１", "仮定縮約２",
    "体言接続特殊", "体言接続特殊２", "ガル接続", "連用ゴザイ接続", "文語基本形",
  ]

  public static func isStemOnly(form: String) -> Bool {
    stemOnlyForms.contains(form)
  }

  /// Suffixes that attach to a stem in the given form.
  ///
  /// Three things decide this, and each of them was a bug before it was
  /// handled:
  ///
  /// - **Which form carries た/て.** 五段 verbs put it on 連用タ接続 (書い+た);
  ///   一段 and the irregulars put it on 連用形 (食べ+た). Confusing them
  ///   produces 書きた.
  /// - **Voicing.** 撥音便 and ガ行 take だ/で, not た/て: 読ん+だ, 泳い+だ.
  ///   Without this 読んだ never exists and 読んた does.
  /// - **サ行五段 has no 連用タ接続 at all.** 話す conjugates 話し+た straight
  ///   off 連用形, so excluding all 五段 from 連用形 loses 話した entirely.
  ///
  /// mozc only labels three 五段 subtypes (カ行イ音便 / カ行促音便ユク /
  /// ラ行特殊) and files the rest under a generic 五段動詞, so the row has to
  /// be recovered from how the stem ends.
  public static func suffixes(form: String, type: String, stemReading: String) -> [Suffix] {
    switch form {
    case "連用タ接続":
      return isVoiced(type: type, stemReading: stemReading) ? voicedPastAndTe : pastAndTe

    case "連用形":
      let polite = [
        s("ます", "ます"), s("ました", "ました"), s("ません", "ません"),
        s("たい", "たい"), s("ながら", "ながら"),
      ]
      guard type.hasPrefix("五段") else { return pastAndTe + polite }
      // サ行五段 (話し, 消し, 出し) is the one 五段 row whose た hangs off
      // 連用形. It is also the only one whose stem ends in し.
      return stemReading.hasSuffix("し") ? pastAndTe + polite : polite

    case "未然形":
      // ず is literary and almost never typed, but 見ず lands on top of 水:
      // an expansion inherits its stem's cost, み→見 is cheap, and the
      // manufactured form undercuts the common noun. mozc has no みず→見ず row
      // at all — this was ours. Every suffix here has to earn its place, and
      // a 文語 form that costs a daily word does not.
      return [s("ない", "ない"), s("なかった", "なかった"), s("なければ", "なければ")]

    case "未然ウ接続":
      return [s("う", "う")]

    case "仮定形":
      return [s("ば", "ば")]

    // 形容詞: 高く
    case "連用テ接続":
      return [s("て", "て"), s("ても", "ても"), s("ない", "ない"), s("なった", "なった")]

    // 形容詞: 高
    case "ガル接続":
      return [s("さ", "さ"), s("そう", "そう")]

    default:
      return []
    }
  }

  private static let pastAndTe = [
    s("た", "た"), s("たら", "たら"), s("たり", "たり"),
    s("て", "て"), s("ても", "ても"), s("てる", "てる"), s("ている", "ている"),
  ]

  private static let voicedPastAndTe = [
    s("だ", "だ"), s("だら", "だら"), s("だり", "だり"),
    s("で", "で"), s("でも", "でも"), s("でる", "でる"), s("でいる", "でいる"),
  ]

  /// 撥音便 (読ん, 飲ん, 呼ん, 死ん) and ガ行 (泳い, 脱い) voice the suffix.
  ///
  /// The ん case is unambiguous. The い case leans on a quirk of the data:
  /// カ行イ音便 has its own label (書い, 聞い), so an い-final stem left under
  /// the generic 五段動詞 is ガ行.
  private static func isVoiced(type: String, stemReading: String) -> Bool {
    if stemReading.hasSuffix("ん") { return true }
    if stemReading.hasSuffix("い"), type == "五段動詞" { return true }
    return false
  }

  /// Suffixes for a サ変接続 noun, which is a verb once する is attached.
  ///
  /// 勉強 is filed as 名詞,サ変接続 and する lives in its own row, so
  /// べんきょうする reaches nothing at all without this. Mozc calls the same
  /// move 語彙化 and measured it at +0.039 BLEU.
  public static let suruSuffixes = [
    s("する", "する"), s("した", "した"), s("して", "して"), s("してる", "してる"),
    s("している", "している"), s("します", "します"), s("しました", "しました"),
    s("しない", "しない"), s("すれば", "すれば"), s("しよう", "しよう"),
  ]

  /// Verbs and adjectives inflect; so do the nouns that take する.
  public static func isInflectable(_ feature: Feature) -> Bool {
    if feature.partOfSpeech.hasPrefix("動詞") || feature.partOfSpeech.hasPrefix("形容詞") {
      return true
    }
    return isSuruNoun(feature)
  }

  public static func isSuruNoun(_ feature: Feature) -> Bool {
    feature.partOfSpeech == "名詞" && feature.subcategory == "サ変接続"
  }

  /// A parsed mozc `id.def` line.
  public struct Feature {
    public var partOfSpeech: String
    public var subcategory: String
    public var conjugationType: String
    public var conjugationForm: String
  }

  /// `1234 動詞,自立,*,*,五段・カ行イ音便,連用タ接続,*`
  public static func parseIdDef(_ text: String) -> [UInt16: Feature] {
    var result: [UInt16: Feature] = [:]
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
      let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
      guard parts.count == 2, let id = UInt16(parts[0]) else { continue }
      let fields = parts[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
      guard fields.count >= 6 else { continue }
      result[id] = Feature(
        partOfSpeech: fields[0], subcategory: fields[1], conjugationType: fields[4],
        conjugationForm: fields[5])
    }
    return result
  }
}
