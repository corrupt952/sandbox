# swift-pdf-render-bench

Standalone Swift scripts benchmarking and optimizing a PDF reader's initial
page-render path: `CGPDFDocumentAdapter`-style full-page rasterization
(`CGContext.drawPDFPage`) plus a Core Image theme filter (invert/sepia for
night/sepia reading modes). Extracted and reimplemented from a real reader
app's render pipeline for isolated measurement — not a dependency on that
app, just the same technique measured out of context.

Sample PDFs are **not included** (any real PDFs used during the original
investigation are proprietary). Point each script at your own PDF(s).

## Scripts

Each file is a self-contained `swiftc`-compilable script.

- **`main.swift`** — baseline measurement: cold vs. warm `drawPDFPage` +
  theme-filter timing, broken into signpost-style stages (snapshot →
  contextAlloc → drawSetup → drawPDF → makeImage → themeApply). Defaults to
  `pdfs/{accessibility,illustration,softwaredesign}.pdf` relative to the
  script, or pass your own paths as arguments.
  ```sh
  swift main.swift path/to/sample1.pdf path/to/sample2.pdf
  ```
- **`parallel.swift`** — splits a page into horizontal bands and rasterizes
  them concurrently with GCD `concurrentPerform`, using per-thread
  `CGPDFDocument` instances (works around the double-free in rdar://19073954)
  and a clip-based band draw. Verifies pixel-identical output against a
  single-threaded render.
  ```sh
  swiftc -O parallel.swift -o parallel && ./parallel
  ```
- **`parallel2.swift`** — refined version: band-sized contexts with a device
  translate instead of clipping (removes clip-edge antialiasing seams,
  giving exact pixel match) and single-pass compositing.
  ```sh
  swiftc -O parallel2.swift -o parallel2 && ./parallel2
  ```
- **`diag.swift`** — visualizes where parallel-band output diverges from
  single-threaded output (per-row max diff, whether it clusters at band
  seams) and checks whether interpretation-bound pages have stable timing
  across repeated runs. Writes `single.png` / `parallel.png` / `diff_amp.png`
  for visual inspection.
  ```sh
  swiftc -O diag.swift -o diag && ./diag
  ```
- **`experiments.swift`** — A/B-tests specific optimization proposals
  against the current approach, one at a time (separate processes to avoid
  cross-contamination), comparing both speed (median) and pixel accuracy
  (max/mean absolute diff).
  ```sh
  swiftc -O experiments.swift -o experiments
  for m in theme-vimage theme-cgblend lowres interp diskcache; do ./experiments $m; done
  ```
- **`outline-order.swift`** / **`outline-dump.swift`** — reproduce a PDF
  reader's outline (table of contents) → page-index resolution logic via
  `PDFKit`, to debug page-ordering issues independent of the render path.

## Results

See [RESULTS.md](RESULTS.md) for the baseline measurements and the
optimizations they motivated.
