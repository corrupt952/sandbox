import Foundation

/// One candidate word occupying `[start, end)` of the input.
public struct LatticeNode {
  public var surface: String
  public var reading: String
  public var start: Int
  public var end: Int
  public var leftId: UInt16
  public var rightId: UInt16
  public var wordCost: Int32
  public var isUnknown: Bool

  /// Best paths reaching the end of this node, cheapest first.
  fileprivate var paths: [Path] = []

  public init(
    surface: String, reading: String, start: Int, end: Int, leftId: UInt16, rightId: UInt16,
    wordCost: Int32, isUnknown: Bool
  ) {
    self.surface = surface
    self.reading = reading
    self.start = start
    self.end = end
    self.leftId = leftId
    self.rightId = rightId
    self.wordCost = wordCost
    self.isUnknown = isUnknown
  }

  fileprivate struct Path {
    var cost: Int32
    var previousNode: Int
    var previousRank: Int
  }
}

/// A finished conversion candidate.
public struct Candidate {
  public struct Segment {
    public var surface: String
    public var reading: String
    public var isUnknown: Bool
  }

  public var text: String
  public var cost: Int32
  public var segments: [Segment]
}

/// Lattice construction plus a k-best Viterbi search.
///
/// Keeping the k cheapest paths at every node (rather than only the single
/// best) turns the same dynamic program into an exact k-shortest-path search
/// over the lattice, which is what produces the candidate list an IME shows.
public struct Lattice {
  private var nodes: [LatticeNode] = []
  private var endingAt: [[Int]] = []
  private var startingAt: [[Int]] = []
  private let length: Int

  private static let bosNode = 0
  private static let eosNode = 1

  public init(inputLength: Int) {
    self.length = inputLength
    self.endingAt = Array(repeating: [], count: inputLength + 1)
    self.startingAt = Array(repeating: [], count: inputLength + 1)

    // BOS/EOS use context ID 0, the same convention as the matrix.
    nodes.append(
      LatticeNode(
        surface: "", reading: "", start: 0, end: 0, leftId: 0, rightId: 0, wordCost: 0,
        isUnknown: false))
    nodes.append(
      LatticeNode(
        surface: "", reading: "", start: inputLength, end: inputLength, leftId: 0, rightId: 0,
        wordCost: 0, isUnknown: false))
    endingAt[0].append(Lattice.bosNode)
    startingAt[inputLength].append(Lattice.eosNode)
  }

  public mutating func insert(_ node: LatticeNode) {
    let index = nodes.count
    nodes.append(node)
    endingAt[node.end].append(index)
    startingAt[node.start].append(index)
  }

  public var isConnected: Bool {
    // Every position that can be reached must also have an outgoing node.
    var reachable = Array(repeating: false, count: length + 1)
    reachable[0] = true
    for position in 0...length where reachable[position] {
      for node in startingAt[position] where node != Lattice.eosNode {
        reachable[nodes[node].end] = true
      }
    }
    return reachable[length]
  }

  /// Runs the search with an explicit transition cost, returning up to `count`
  /// candidates, cheapest first.
  ///
  /// The transition is a closure rather than a connection matrix so the same
  /// search serves both models: a POS bigram matrix, or a flat per-boundary
  /// penalty that needs no part-of-speech at all. Swapping in a word bigram
  /// later touches only this argument.
  public mutating func search(
    count: Int, transition: (LatticeNode, LatticeNode) -> Int32
  ) -> [Candidate] {
    guard count > 0 else { return [] }
    nodes[Lattice.bosNode].paths = [LatticeNode.Path(cost: 0, previousNode: -1, previousRank: -1)]

    for position in 0...length {
      for nodeIndex in startingAt[position] {
        var candidates: [LatticeNode.Path] = []
        let node = nodes[nodeIndex]
        for previousIndex in endingAt[position] {
          let previous = nodes[previousIndex]
          guard !previous.paths.isEmpty else { continue }
          let step = transition(previous, node)
          for (rank, path) in previous.paths.enumerated() {
            candidates.append(
              LatticeNode.Path(
                cost: path.cost + step + node.wordCost, previousNode: previousIndex,
                previousRank: rank))
          }
        }
        candidates.sort { $0.cost < $1.cost }
        if candidates.count > count { candidates.removeSubrange(count...) }
        nodes[nodeIndex].paths = candidates
      }
    }

    return nodes[Lattice.eosNode].paths.indices.map { backtrack(rank: $0) }
  }

  /// Convenience for the POS bigram model.
  public mutating func search(matrix: ConnectionMatrix, count: Int) -> [Candidate] {
    search(count: count) { previous, node in
      matrix.cost(from: previous.rightId, to: node.leftId)
    }
  }

  /// Convenience for the flat model: every boundary costs the same, so the
  /// cheapest path is the one with fewest segments once word costs tie. This
  /// is the classic 文節数最小法, expressed as a cost.
  public mutating func search(boundaryCost: Int32, count: Int) -> [Candidate] {
    search(count: count) { _, _ in boundaryCost }
  }

  private func backtrack(rank: Int) -> Candidate {
    var segments: [Candidate.Segment] = []
    var nodeIndex = Lattice.eosNode
    var pathRank = rank
    let totalCost = nodes[Lattice.eosNode].paths[rank].cost

    while nodeIndex != Lattice.bosNode {
      let node = nodes[nodeIndex]
      if nodeIndex != Lattice.eosNode {
        segments.append(
          Candidate.Segment(
            surface: node.surface, reading: node.reading, isUnknown: node.isUnknown))
      }
      let path = node.paths[pathRank]
      nodeIndex = path.previousNode
      pathRank = path.previousRank
    }
    segments.reverse()

    return Candidate(
      text: segments.map(\.surface).joined(), cost: totalCost, segments: segments)
  }
}
