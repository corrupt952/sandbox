//
//  ActivityShareSheet.swift
//  BevLab
//
//  Created by K@zuki. on 2026/07/13.
//

import SwiftUI
import UIKit

/// Thin SwiftUI wrapper around `UIActivityViewController` for sharing file
/// URLs (save to Files/Photos, AirDrop, …). Used instead of `ShareLink`
/// because the shared item is produced lazily on tap — encoding a PNG on
/// every view update just to keep a `ShareLink` fed would put per-frame
/// work back on the main thread.
struct ActivityShareSheet: UIViewControllerRepresentable {
  /// Items to share, typically a single file URL.
  let activityItems: [Any]

  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
  }

  func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
