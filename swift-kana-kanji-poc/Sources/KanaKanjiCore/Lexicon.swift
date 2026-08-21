import Foundation

/// Reading-keyed lexicon, memory-mapped and searched in place.
///
/// A double-array trie would be the textbook choice, but a sorted key table
/// with a binary search per prefix length is enough here: the input of a single
/// conversion is a few dozen characters, so lookups are bounded by
/// `inputLength * maxKeyLength * log(keyCount)`.
public final class Lexicon {
  static let formatVersion: UInt32 = 1

  public struct Entry {
    public var surface: String
    public var leftId: UInt16
    public var rightId: UInt16
    public var cost: Int16
  }

  private let data: Data
  private let keyCount: Int
  private let entryCount: Int
  private let keysOffset: Int
  private let entriesOffset: Int
  private let stringsOffset: Int

  private static let headerSize = 16
  private static let keyRecordSize = 12
  private static let entryRecordSize = 12

  public init(contentsOf url: URL) throws {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    guard data.count >= Lexicon.headerSize else { throw FormatError.truncated(url.path) }

    let header: (magicOK: Bool, version: UInt32, keys: UInt32, entries: UInt32) =
      data.withUnsafeBytes { buffer in
        let magic =
          buffer[0] == 0x4B && buffer[1] == 0x4B && buffer[2] == 0x43 && buffer[3] == 0x44
        return (magic, LE.u32(buffer, 4), LE.u32(buffer, 8), LE.u32(buffer, 12))
      }
    guard header.magicOK else { throw FormatError.badMagic(url.path) }
    guard header.version == Lexicon.formatVersion else {
      throw FormatError.unsupportedVersion(header.version)
    }

    self.data = data
    self.keyCount = Int(header.keys)
    self.entryCount = Int(header.entries)
    self.keysOffset = Lexicon.headerSize
    self.entriesOffset = keysOffset + keyCount * Lexicon.keyRecordSize
    self.stringsOffset = entriesOffset + entryCount * Lexicon.entryRecordSize
    guard data.count >= stringsOffset else { throw FormatError.truncated(url.path) }
  }

  public var numberOfKeys: Int { keyCount }
  public var numberOfEntries: Int { entryCount }

  /// Longest key in the lexicon, in UTF-8 bytes. Bounds the prefix search.
  public private(set) lazy var maxKeyByteLength: Int = {
    var maximum = 0
    data.withUnsafeBytes { buffer in
      for index in 0..<keyCount {
        let length = Int(LE.u16(buffer, keysOffset + index * Lexicon.keyRecordSize + 4))
        if length > maximum { maximum = length }
      }
    }
    return maximum
  }()

  /// Every distinct surface in the lexicon.
  ///
  /// Counting words in raw text needs to know what counts as a word, and the
  /// dictionary is the only answer available. Iterating entries rather than
  /// keys because the same surface appears under many readings.
  public func allSurfaces() -> Set<String> {
    data.withUnsafeBytes { buffer -> Set<String> in
      var surfaces: Set<String> = []
      surfaces.reserveCapacity(entryCount / 2)
      for index in 0..<entryCount {
        let entry = entriesOffset + index * Lexicon.entryRecordSize
        let offset = Int(LE.u32(buffer, entry))
        let length = Int(LE.u16(buffer, entry + 4))
        surfaces.insert(string(at: offset, length: length, in: buffer))
      }
      return surfaces
    }
  }

  /// All entries whose reading is exactly `key`.
  public func entries(forKey key: [UInt8]) -> [Entry] {
    data.withUnsafeBytes { buffer -> [Entry] in
      guard let keyIndex = search(key, in: buffer) else { return [] }
      let record = keysOffset + keyIndex * Lexicon.keyRecordSize
      let count = Int(LE.u16(buffer, record + 6))
      let start = Int(LE.u32(buffer, record + 8))
      return (0..<count).map { offset in
        let entry = entriesOffset + (start + offset) * Lexicon.entryRecordSize
        let surfaceOffset = Int(LE.u32(buffer, entry))
        let surfaceLength = Int(LE.u16(buffer, entry + 4))
        return Entry(
          surface: string(at: surfaceOffset, length: surfaceLength, in: buffer),
          leftId: LE.u16(buffer, entry + 6),
          rightId: LE.u16(buffer, entry + 8),
          cost: LE.i16(buffer, entry + 10))
      }
    }
  }

  /// Keys that start with `prefix`, in sorted order, with their entries.
  ///
  /// This is what an IME needs while the reading is still being typed: the
  /// candidate list has to update on every keystroke, before the user has
  /// finished the word.
  public func entries(withPrefix prefix: [UInt8], maxKeys: Int) -> [(key: String, entries: [Entry])]
  {
    guard !prefix.isEmpty, maxKeys > 0 else { return [] }
    return data.withUnsafeBytes { buffer -> [(String, [Entry])] in
      var index = lowerBound(prefix, in: buffer)
      var results: [(String, [Entry])] = []
      while index < keyCount, results.count < maxKeys {
        let record = keysOffset + index * Lexicon.keyRecordSize
        let offset = stringsOffset + Int(LE.u32(buffer, record))
        let length = Int(LE.u16(buffer, record + 4))
        guard length >= prefix.count, hasPrefix(prefix, at: offset, in: buffer) else { break }

        let count = Int(LE.u16(buffer, record + 6))
        let start = Int(LE.u32(buffer, record + 8))
        let key = String(
          decoding: UnsafeRawBufferPointer(rebasing: buffer[offset..<(offset + length)]),
          as: UTF8.self)
        results.append((key, readEntries(start: start, count: count, in: buffer)))
        index += 1
      }
      return results
    }
  }

  /// First key index whose bytes are >= `key`.
  private func lowerBound(_ key: [UInt8], in buffer: UnsafeRawBufferPointer) -> Int {
    var low = 0
    var high = keyCount
    while low < high {
      let mid = (low + high) / 2
      let record = keysOffset + mid * Lexicon.keyRecordSize
      let offset = stringsOffset + Int(LE.u32(buffer, record))
      let length = Int(LE.u16(buffer, record + 4))
      if compare(key, against: buffer, offset: offset, length: length) > 0 {
        low = mid + 1
      } else {
        high = mid
      }
    }
    return low
  }

  private func hasPrefix(
    _ prefix: [UInt8], at offset: Int, in buffer: UnsafeRawBufferPointer
  ) -> Bool {
    for index in 0..<prefix.count where buffer[offset + index] != prefix[index] {
      return false
    }
    return true
  }

  private func readEntries(
    start: Int, count: Int, in buffer: UnsafeRawBufferPointer
  ) -> [Entry] {
    (0..<count).map { offset in
      let entry = entriesOffset + (start + offset) * Lexicon.entryRecordSize
      let surfaceOffset = Int(LE.u32(buffer, entry))
      let surfaceLength = Int(LE.u16(buffer, entry + 4))
      return Entry(
        surface: string(at: surfaceOffset, length: surfaceLength, in: buffer),
        leftId: LE.u16(buffer, entry + 6),
        rightId: LE.u16(buffer, entry + 8),
        cost: LE.i16(buffer, entry + 10))
    }
  }

  private func search(_ key: [UInt8], in buffer: UnsafeRawBufferPointer) -> Int? {
    var low = 0
    var high = keyCount - 1
    while low <= high {
      let mid = (low + high) / 2
      let record = keysOffset + mid * Lexicon.keyRecordSize
      let offset = stringsOffset + Int(LE.u32(buffer, record))
      let length = Int(LE.u16(buffer, record + 4))
      let order = compare(key, against: buffer, offset: offset, length: length)
      if order == 0 { return mid }
      if order < 0 { high = mid - 1 } else { low = mid + 1 }
    }
    return nil
  }

  private func compare(
    _ key: [UInt8], against buffer: UnsafeRawBufferPointer, offset: Int, length: Int
  ) -> Int {
    let shared = min(key.count, length)
    var index = 0
    while index < shared {
      let lhs = key[index]
      let rhs = buffer[offset + index]
      if lhs != rhs { return lhs < rhs ? -1 : 1 }
      index += 1
    }
    if key.count == length { return 0 }
    return key.count < length ? -1 : 1
  }

  private func string(at offset: Int, length: Int, in buffer: UnsafeRawBufferPointer) -> String {
    let start = stringsOffset + offset
    let bytes = UnsafeRawBufferPointer(rebasing: buffer[start..<(start + length)])
    return String(decoding: bytes, as: UTF8.self)
  }
}
