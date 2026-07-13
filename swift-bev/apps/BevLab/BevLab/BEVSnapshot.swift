//
//  BEVSnapshot.swift
//  BevLab
//
//  Created by K@zuki. on 2026/07/13.
//

import Foundation

/// A PNG snapshot of the rectified BEV image at its native resolution (no
/// screen scaling), so measurements taken on the saved file map 1:1 to
/// output pixels.
///
/// The filename encodes the ground-rectangle size so the metric scale
/// (mm/px = rectMeters * 1000 / pixel size) can be reconstructed from the
/// file alone, e.g. `bev-100cm-20260713-153012.png`.
struct BEVSnapshot: Identifiable {
  /// PNG-encoded image data at the pipeline's native output size.
  let pngData: Data

  /// Filename carrying the ground-rectangle size and a timestamp.
  let filename: String

  var id: String { filename }

  /// Writes the PNG into a temporary directory under `filename` and returns
  /// its URL, so share destinations (Files, AirDrop, Photos) see a properly
  /// named file instead of anonymous data.
  func writeToTemporaryFile() -> URL? {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    do {
      try pngData.write(to: url, options: .atomic)
      return url
    } catch {
      return nil
    }
  }
}
