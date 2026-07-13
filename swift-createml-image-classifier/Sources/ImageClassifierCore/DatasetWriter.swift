import CoreGraphics
import Foundation

public enum DatasetWriterError: Error {
  case encodingFailed
}

@MainActor
public protocol DatasetWriterProtocol {
  func write(_ image: CGImage, label: String, index: Int) throws
}

@MainActor
public final class DatasetWriter: DatasetWriterProtocol {
  private let rootURL: URL
  private let fileManager: FileManager

  public init(rootURL: URL, fileManager: FileManager = .default) {
    self.rootURL = rootURL
    self.fileManager = fileManager
  }

  public func write(_ image: CGImage, label: String, index: Int) throws {
    let directoryURL = rootURL.appending(path: label)
    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

    guard let data = PNGEncoder.encode(image) else {
      throw DatasetWriterError.encodingFailed
    }

    let fileName = String(format: "%@_%04d.png", label, index)
    try data.write(to: directoryURL.appending(path: fileName))
  }
}
