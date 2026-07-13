import Foundation
import MLX
import MNISTCore

enum MNISTDatasetError: Error, CustomStringConvertible {
  case downloadFailed(file: String, status: Int)

  var description: String {
    switch self {
    case .downloadFailed(let file, let status):
      return "Failed to download \(file): HTTP \(status)"
    }
  }
}

/// MNIST split loaded as MLX arrays: images normalized to [0, 1] with shape
/// [count, 28, 28, 1], labels as Int32 with shape [count].
struct MNISTSplit {
  let images: MLXArray
  let labels: MLXArray
}

/// Downloads the four IDX .gz files (when absent), gunzips and parses them with
/// MNISTCore, and builds MLX arrays. No third-party code is involved: download
/// via URLSession, gunzip via Compression, parse via the bounded IDXParser.
enum MNISTDataset {
  private static let files = [
    "train-images-idx3-ubyte.gz",
    "train-labels-idx1-ubyte.gz",
    "t10k-images-idx3-ubyte.gz",
    "t10k-labels-idx1-ubyte.gz",
  ]

  static func load(
    into directory: URL,
    baseURL: String
  ) async throws -> (train: MNISTSplit, test: MNISTSplit) {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for file in files {
      try await downloadIfNeeded(file, into: directory, baseURL: baseURL)
    }

    let train = try makeSplit(
      imagesFile: "train-images-idx3-ubyte.gz",
      labelsFile: "train-labels-idx1-ubyte.gz",
      in: directory
    )
    let test = try makeSplit(
      imagesFile: "t10k-images-idx3-ubyte.gz",
      labelsFile: "t10k-labels-idx1-ubyte.gz",
      in: directory
    )
    return (train, test)
  }

  private static func downloadIfNeeded(
    _ file: String,
    into directory: URL,
    baseURL: String
  ) async throws {
    let destination = directory.appending(path: file)
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      return
    }

    let url = URL(string: baseURL)!.appending(path: file)
    print("Download: \(file)")
    let (data, response) = try await URLSession.shared.data(from: url)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else {
      throw MNISTDatasetError.downloadFailed(file: file, status: status)
    }
    try data.write(to: destination)
  }

  private static func makeSplit(
    imagesFile: String,
    labelsFile: String,
    in directory: URL
  ) throws -> MNISTSplit {
    let imagesData = try GzipDecoder.inflate(
      try Data(contentsOf: directory.appending(path: imagesFile))
    )
    let labelsData = try GzipDecoder.inflate(
      try Data(contentsOf: directory.appending(path: labelsFile))
    )

    let images = try IDXParser.parseImages(imagesData)
    let labels = try IDXParser.parseLabels(labelsData)

    let pixels = MLXArray(images.pixels).asType(.float32) / 255.0
    let imageArray = pixels.reshaped([images.count, images.rows, images.columns, 1])
    let labelArray = MLXArray(labels.values.map { Int32($0) })

    return MNISTSplit(images: imageArray, labels: labelArray)
  }
}
