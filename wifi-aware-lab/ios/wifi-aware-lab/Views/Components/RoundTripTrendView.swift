import SwiftUI

struct RoundTripTrendView: View {
  // MARK: - Static properties

  private static let size = CGSize(width: 84, height: 16)

  // MARK: - Properties

  let roundTrips: [Duration]

  var body: some View {
    Canvas { context, size in
      guard let path = path(in: size) else { return }

      context.stroke(
        path,
        with: .color(.accentColor),
        style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
      )
    }
    .frame(width: Self.size.width, height: Self.size.height)
    .accessibilityLabel(accessibilityText)
  }

  // MARK: - Private methods

  private func path(in size: CGSize) -> Path? {
    let values = roundTrips.map(\.totalMilliseconds)
    guard values.count >= 2 else { return nil }

    let lowest = values.min() ?? 0
    let highest = values.max() ?? 0
    // A flat line would divide by zero, so pin it to the middle instead.
    let span = highest - lowest
    let step = size.width / Double(values.count - 1)
    let inset = 1.5

    var path = Path()
    for (index, value) in values.enumerated() {
      let ratio = span > 0 ? (value - lowest) / span : 0.5
      let point = CGPoint(
        x: Double(index) * step,
        y: inset + (1 - ratio) * (size.height - inset * 2)
      )
      index == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    return path
  }

  private var accessibilityText: String {
    let values = roundTrips.map(\.totalMilliseconds)
    guard let lowest = values.min(), let highest = values.max() else { return "" }

    return String(
      format: "Round trip trend, last %d pings, %.1f to %.1f milliseconds",
      values.count,
      lowest,
      highest
    )
  }
}

#Preview {
  RoundTripTrendView(
    roundTrips: [16, 13, 15, 14, 14, 13, 14, 13].map { .milliseconds($0) }
  )
  .padding()
}
