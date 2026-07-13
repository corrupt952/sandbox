import CoreGraphics
import Foundation

public struct SyntheticSampleRenderer {
  public let canvasSize: Int

  public init(canvasSize: Int = 128) {
    self.canvasSize = canvasSize
  }

  public func render(
    shape: SyntheticShape,
    using generator: inout some RandomNumberGenerator
  ) -> CGImage? {
    guard
      let context = CGContext(
        data: nil,
        width: canvasSize,
        height: canvasSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      return nil
    }

    fillBackground(in: context, using: &generator)
    drawShape(shape, in: context, using: &generator)

    return context.makeImage()
  }

  private func fillBackground(
    in context: CGContext,
    using generator: inout some RandomNumberGenerator
  ) {
    let tint = CGFloat.random(in: 0.85...1.0, using: &generator)
    context.setFillColor(
      CGColor(
        red: tint,
        green: CGFloat.random(in: 0.85...1.0, using: &generator),
        blue: CGFloat.random(in: 0.85...1.0, using: &generator),
        alpha: 1
      ))
    context.fill(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))
  }

  private func drawShape(
    _ shape: SyntheticShape,
    in context: CGContext,
    using generator: inout some RandomNumberGenerator
  ) {
    let canvas = CGFloat(canvasSize)
    let size = canvas * CGFloat.random(in: 0.4...0.7, using: &generator)
    let jitterRange = -canvas * 0.15...canvas * 0.15
    let centerX = canvas / 2 + CGFloat.random(in: jitterRange, using: &generator)
    let centerY = canvas / 2 + CGFloat.random(in: jitterRange, using: &generator)
    let rotation = CGFloat.random(in: 0..<(2 * .pi), using: &generator)

    context.setFillColor(
      CGColor(
        red: CGFloat.random(in: 0.0...0.7, using: &generator),
        green: CGFloat.random(in: 0.0...0.7, using: &generator),
        blue: CGFloat.random(in: 0.0...0.7, using: &generator),
        alpha: 1
      ))

    context.saveGState()
    context.translateBy(x: centerX, y: centerY)
    context.rotate(by: rotation)

    let rect = CGRect(x: -size / 2, y: -size / 2, width: size, height: size)
    switch shape {
    case .circle:
      context.fillEllipse(in: rect)
    case .square:
      context.fill(rect)
    case .triangle:
      context.beginPath()
      context.move(to: CGPoint(x: 0, y: size / 2))
      context.addLine(to: CGPoint(x: -size / 2, y: -size / 2))
      context.addLine(to: CGPoint(x: size / 2, y: -size / 2))
      context.closePath()
      context.fillPath()
    }

    context.restoreGState()
  }
}
