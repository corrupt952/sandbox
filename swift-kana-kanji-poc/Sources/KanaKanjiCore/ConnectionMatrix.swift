import Foundation

/// Connection (bigram) costs between context IDs.
///
/// This is the half of the model the lexicon cannot express: how well the right
/// context of one word joins the left context of the next. Everything the
/// converter does beyond dictionary lookup comes down to minimising the sum of
/// word costs and these transition costs.
public struct ConnectionMatrix {
  static let formatVersion: UInt32 = 1

  public let leftSize: Int
  public let rightSize: Int
  private let costs: [Int16]

  /// In-memory matrix, for tests and synthetic models.
  public init(leftSize: Int, rightSize: Int, costs: [Int16]) {
    precondition(costs.count == leftSize * rightSize)
    self.leftSize = leftSize
    self.rightSize = rightSize
    self.costs = costs
  }

  public init(contentsOf url: URL) throws {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    guard data.count >= 16 else { throw FormatError.truncated(url.path) }

    var leftSize = 0
    var rightSize = 0
    var costs: [Int16] = []
    try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
      let magic = buffer[0] == 0x4B && buffer[1] == 0x4B && buffer[2] == 0x43 && buffer[3] == 0x4D
      guard magic else { throw FormatError.badMagic(url.path) }
      let version = LE.u32(buffer, 4)
      guard version == ConnectionMatrix.formatVersion else {
        throw FormatError.unsupportedVersion(version)
      }
      leftSize = Int(LE.u32(buffer, 8))
      rightSize = Int(LE.u32(buffer, 12))
      let expected = 16 + leftSize * rightSize * 2
      guard buffer.count >= expected else { throw FormatError.truncated(url.path) }

      costs = [Int16](repeating: 0, count: leftSize * rightSize)
      for index in 0..<costs.count {
        costs[index] = LE.i16(buffer, 16 + index * 2)
      }
    }

    self.leftSize = leftSize
    self.rightSize = rightSize
    self.costs = costs
  }

  /// Cost of placing a node whose left context is `rightNodeLeftId` after a
  /// node whose right context is `leftNodeRightId`.
  @inline(__always)
  public func cost(from leftNodeRightId: UInt16, to rightNodeLeftId: UInt16) -> Int32 {
    let lid = Int(leftNodeRightId)
    let rid = Int(rightNodeLeftId)
    guard lid < leftSize, rid < rightSize else { return 0 }
    return Int32(costs[lid + rid * leftSize])
  }
}
