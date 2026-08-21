import Foundation

/// Kana helpers. The lexicon is keyed by reading, and ipadic writes readings in
/// katakana, so everything is normalised to hiragana on both sides.
public enum Kana {
  /// Katakana -> hiragana. Leaves the prolonged sound mark, punctuation and
  /// anything non-katakana untouched.
  public static func toHiragana(_ text: String) -> String {
    var out = String.UnicodeScalarView()
    out.reserveCapacity(text.unicodeScalars.count)
    for scalar in text.unicodeScalars {
      // U+30A1..U+30F6 maps onto U+3041..U+3096 one-to-one.
      if scalar.value >= 0x30A1, scalar.value <= 0x30F6 {
        out.append(Unicode.Scalar(scalar.value - 0x60)!)
      } else {
        out.append(scalar)
      }
    }
    return String(out)
  }

  /// Hiragana -> katakana. The inverse of `toHiragana`, and the reason
  /// character-type conversion needs no dictionary at all: it is derivable
  /// from the reading, so it sits outside the index layer entirely.
  public static func toKatakana(_ text: String) -> String {
    var out = String.UnicodeScalarView()
    out.reserveCapacity(text.unicodeScalars.count)
    for scalar in text.unicodeScalars {
      if scalar.value >= 0x3041, scalar.value <= 0x3096 {
        out.append(Unicode.Scalar(scalar.value + 0x60)!)
      } else {
        out.append(scalar)
      }
    }
    return String(out)
  }

  /// True when every scalar is hiragana, katakana or the prolonged sound mark.
  public static func isAllKana(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    for scalar in text.unicodeScalars {
      let v = scalar.value
      let hiragana = (0x3041...0x3096).contains(v)
      let katakana = (0x30A1...0x30FA).contains(v)
      let marks = v == 0x30FC || v == 0x309B || v == 0x309C
      if !(hiragana || katakana || marks) { return false }
    }
    return true
  }
}
