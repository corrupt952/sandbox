# render-bench results

Target: a reader app's initial render path (full-page raster generation +
theme filter application).

Test machine: macOS / Apple Silicon (**real iPad/iPhone hardware runs roughly
2-4x slower** — look at the ratios between stages, not the absolute numbers).
Conditions: viewBounds 393x852pt x screenScale 3 → output ~1800x2556px. Warm
values are the median of 5 runs on the same page; each PDF/theme combination
is averaged over 5 sample pages.

## Baseline (before optimization)

| PDF type | Theme | cold (first render) | warm | drawPDF | ciRender |
|-----|--------|-----------|------|---------|----------|
| text-heavy | off | 28.3ms | 30.7ms | 28.6 | 0.0 |
| | night | 31.6ms | 39.1ms | 28.3 | **8.6** |
| | sepia | 32.7ms | 40.0ms | 28.8 | **8.9** |
| image-heavy | off | **384.0ms** | 34.0ms | 31.9 | 0.0 |
| | night | 40.6ms | 42.9ms | 31.4 | **9.3** |
| | sepia | 40.1ms | 42.9ms | 31.4 | **9.4** |
| magazine layout | off | 50.5ms | 43.6ms | 41.3 | 0.0 |
| | night | 50.9ms | 53.1ms | 41.6 | **9.2** |
| | sepia | 48.8ms | 50.2ms | 39.5 | **8.8** |

snapshot / ctxAlloc / drawSetup / makeImage / ciBuild are all < 2.2ms
(negligible).

## Root cause

1. **`drawPDFPage` dominates (28-41ms warm)** — confirms hypothesis 1: full-
   page raster generation is the bulk of the initial-render critical path.
2. **The theme filter (`CIColorInvert`/`CISepiaTone` via `createCGImage`)
   adds ~9ms** — confirms hypothesis 2. This is essentially the entire gap
   between the "off" theme and the others, and the cause of extra perceived
   latency on non-default themes.
3. **384ms cold render for the image-heavy PDF** is the first-time decode of
   embedded images. Once decoded, warm render drops to 34ms — this decode is
   the cold-start spike.
4. Hypothesis 3 (prewarm contending with the initial render on a serial
   queue) doesn't reproduce in isolated measurement, but on real devices a
   longer `drawPDF` makes the visible page more likely to queue behind
   prewarm. Shortening `drawPDF` secondarily mitigates this.

## Direction for improvement (by impact, descending)

- **A. Two-pass render: low-res first, full-res second.** Both `drawPDF` and
  the filter scale with pixel count, so rendering the first pass at a lower
  scale drastically cuts time-to-first-pixel. Helps off/night/sepia alike,
  and shrinks hypothesis 2's overhead on the first pass too — one mechanism
  addresses both complaints.
- **B. Move the theme filter to vImage (Accelerate/CPU).** Avoids GPU
  round-trip (upload/download) latency; invert is a trivially cheap table
  lookup.
