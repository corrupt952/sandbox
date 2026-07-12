# swift-livetext-demo

Minimal demo of VisionKit Live Text: open an image, run on-device OCR
(`ImageAnalyzer`), then select and copy text directly on top of the image via
`ImageAnalysisOverlayView`.

## Features

- Open any image and run OCR automatically after load
- Drag-select text in the image (handled natively by the overlay view)
- "Extract text" dumps the full transcript (`analysis.transcript`, macOS 14+)
  into a side panel
- Optional pre-processing (contrast / saturation via `CIColorControls`)
  before OCR, useful for improving hit rate on colored/busy backgrounds

## Requirements

macOS 13+ (Ventura) with Neural Engine (Apple Silicon or supported Intel Mac).

## How to run

```sh
swift main.swift
```
