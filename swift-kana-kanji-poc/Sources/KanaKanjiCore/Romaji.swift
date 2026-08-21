import Foundation

/// Romaji to kana, incrementally.
///
/// The harness needs this because the point is to feel what typing is like,
/// and typing Japanese starts at the keyboard, not at the reading. Kept
/// deliberately plain: greedy longest match, with the two rules that are not
/// table lookups (sokuon and syllabic n).
public enum Romaji {
  /// Converts as much of `input` as is unambiguous, returning the kana
  /// produced and the tail that could still grow into something else.
  public static func convert(_ input: String) -> (kana: String, pending: String) {
    var kana = ""
    var rest = Substring(input.lowercased())

    while !rest.isEmpty {
      // Sokuon: a doubled consonant becomes っ and the second one carries on.
      if rest.count >= 2 {
        let first = rest[rest.startIndex]
        let second = rest[rest.index(after: rest.startIndex)]
        if first == second, isConsonant(first), first != "n" {
          kana.append("っ")
          rest = rest.dropFirst()
          continue
        }
      }

      // Syllabic n: ん before a consonant that cannot start a ny- mora.
      if rest.first == "n", rest.count >= 2 {
        let next = rest[rest.index(after: rest.startIndex)]
        if next == "n" {
          // "nn" usually means ん and nothing else (honnda -> ほんだ). But when
          // an n-mora follows, only the first n is the ん: konnyaku is
          // こ + ん + にゃ + く, and kanna is か + ん + な.
          let third = rest.count >= 3 ? rest[rest.index(rest.startIndex, offsetBy: 2)] : nil
          let startsAnNMora = third.map { "aiueoy".contains($0) } ?? false
          kana.append("ん")
          rest = rest.dropFirst(startsAnNMora ? 1 : 2)
          continue
        }
        if isConsonant(next), next != "y" {
          kana.append("ん")
          rest = rest.dropFirst()
          continue
        }
      }

      var matched = false
      for length in stride(from: min(4, rest.count), through: 1, by: -1) {
        let candidate = String(rest.prefix(length))
        if let value = table[candidate] {
          kana += value
          rest = rest.dropFirst(length)
          matched = true
          break
        }
      }
      if matched { continue }

      // Could this still become a mora if the user keeps typing?
      if isPrefixOfSomeMora(rest) { break }

      // Nothing will ever match: pass the character through.
      kana.append(rest[rest.startIndex])
      rest = rest.dropFirst()
    }

    return (kana, String(rest))
  }

  private static func isConsonant(_ character: Character) -> Bool {
    guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
      return false
    }
    let isLetter = (0x61...0x7A).contains(Int(scalar.value))
    return isLetter && !"aiueo".contains(character)
  }

  private static func isPrefixOfSomeMora(_ text: Substring) -> Bool {
    let prefix = String(text)
    for key in table.keys where key.hasPrefix(prefix) { return true }
    return false
  }

  static let table: [String: String] = {
    var table: [String: String] = [:]

    func put(_ pairs: [String: String]) { table.merge(pairs) { current, _ in current } }

    put([
      "a": "あ", "i": "い", "u": "う", "e": "え", "o": "お",
      "ka": "か", "ki": "き", "ku": "く", "ke": "け", "ko": "こ",
      "ga": "が", "gi": "ぎ", "gu": "ぐ", "ge": "げ", "go": "ご",
      "sa": "さ", "si": "し", "shi": "し", "su": "す", "se": "せ", "so": "そ",
      "za": "ざ", "zi": "じ", "ji": "じ", "zu": "ず", "ze": "ぜ", "zo": "ぞ",
      "ta": "た", "ti": "ち", "chi": "ち", "tu": "つ", "tsu": "つ", "te": "て", "to": "と",
      "da": "だ", "di": "ぢ", "du": "づ", "de": "で", "do": "ど",
      "na": "な", "ni": "に", "nu": "ぬ", "ne": "ね", "no": "の",
      "ha": "は", "hi": "ひ", "hu": "ふ", "fu": "ふ", "he": "へ", "ho": "ほ",
      "ba": "ば", "bi": "び", "bu": "ぶ", "be": "べ", "bo": "ぼ",
      "pa": "ぱ", "pi": "ぴ", "pu": "ぷ", "pe": "ぺ", "po": "ぽ",
      "ma": "ま", "mi": "み", "mu": "む", "me": "め", "mo": "も",
      "ya": "や", "yu": "ゆ", "yo": "よ",
      "ra": "ら", "ri": "り", "ru": "る", "re": "れ", "ro": "ろ",
      "wa": "わ", "wo": "を", "nn": "ん", "n'": "ん",
    ])

    // Youon, generated so the variants stay consistent. Never overwrites a
    // mora that is already in the table: "shi" is し, not しぃ, and "ji" is じ.
    func youon(_ pairs: [String: String], vowels: [String: String]) {
      for (consonant, base) in pairs {
        for (vowel, small) in vowels where table["\(consonant)\(vowel)"] == nil {
          table["\(consonant)\(vowel)"] = base + small
        }
      }
    }
    let allVowels = ["a": "ゃ", "u": "ゅ", "o": "ょ", "i": "ぃ", "e": "ぇ"]
    youon(
      [
        "ky": "き", "gy": "ぎ", "sy": "し", "zy": "じ", "jy": "じ", "ty": "ち",
        "dy": "ぢ", "ny": "に", "hy": "ひ", "by": "び", "py": "ぴ", "my": "み", "ry": "り",
      ], vowels: allVowels)
    // Digraphs only take the three real youon; their i/e forms are separate
    // moras spelled out below.
    youon(["sh": "し", "ch": "ち", "j": "じ"], vowels: ["a": "ゃ", "u": "ゅ", "o": "ょ"])
    put(["je": "じぇ", "che": "ちぇ", "she": "しぇ"])

    // Foreign sounds.
    put([
      "fa": "ふぁ", "fi": "ふぃ", "fe": "ふぇ", "fo": "ふぉ",
      "va": "ゔぁ", "vi": "ゔぃ", "vu": "ゔ", "ve": "ゔぇ", "vo": "ゔぉ",
      "tha": "てゃ", "thi": "てぃ", "thu": "てゅ", "the": "てぇ", "tho": "てょ",
      "dha": "でゃ", "dhi": "でぃ", "dhu": "でゅ", "dhe": "でぇ", "dho": "でょ",
      "tsa": "つぁ", "tsi": "つぃ", "tse": "つぇ", "tso": "つぉ",
      "wi": "うぃ", "we": "うぇ",
    ])

    // Explicit small kana.
    for (prefix, _) in ["x": "", "l": ""] {
      put([
        "\(prefix)a": "ぁ", "\(prefix)i": "ぃ", "\(prefix)u": "ぅ", "\(prefix)e": "ぇ",
        "\(prefix)o": "ぉ", "\(prefix)tu": "っ", "\(prefix)tsu": "っ",
        "\(prefix)ya": "ゃ", "\(prefix)yu": "ゅ", "\(prefix)yo": "ょ", "\(prefix)wa": "ゎ",
      ])
    }

    // Punctuation, as an IME maps it.
    put([
      "-": "ー", ",": "、", ".": "。", "/": "・",
      "[": "「", "]": "」", "!": "！", "?": "？", "~": "〜",
    ])

    return table
  }()
}
