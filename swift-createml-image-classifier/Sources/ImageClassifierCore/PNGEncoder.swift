import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PNGEncoder {
  public static func encode(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data,
        UTType.png.identifier as CFString,
        1,
        nil
      )
    else {
      return nil
    }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      return nil
    }

    return data as Data
  }
}
