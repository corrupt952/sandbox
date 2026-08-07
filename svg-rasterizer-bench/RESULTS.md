# Results

macOS 26.6 / Apple Silicon, Chrome 151.0.7922.108, resvg 0.48.0 (whatever
`nixos-unstable` currently provides), sips from the OS. Reproduce with
`./render.sh`, `python3 compare.py`, `./bench.sh`. An earlier pass on resvg
0.47.0 produced identical diff percentages and 29 ms/image.

## Speed

`./bench.sh 3`, rendering `figures/01-marker-gradient-filter.svg`:

| | ms/image |
|---|---|
| resvg | 23 |
| sips | 51 |
| chrome (baseline flags) | 1576 |
| chrome (baseline, `about:blank`) | 1551 |
| chrome (+ slim flags) | 1546 |
| chrome (+ slim, `about:blank`) | 1555 |

resvg beats sips despite being a separate 3.3 MB binary rather than an OS
built-in.

### Chrome's cost is startup, not rendering

`about:blank` — a page that draws nothing — takes the same time as the SVG.
The rendering itself is lost in the noise, so flag tuning has nothing to
work on. The "slim flags" set was:

```
--disable-extensions --disable-background-networking --disable-sync
--disable-default-apps --no-first-run --disable-component-update
--disable-client-side-phishing-detection --metrics-recording-only --mute-audio
--disable-backgrounding-occluded-windows --disable-renderer-backgrounding
--disable-features=Translate,MediaRouter,OptimizationHints
```

It changed nothing. `--headless=old` still works on Chrome 151 and is also
unchanged (1582 ms in a separate run).

**Trap: do not pass `--user-data-dir` to isolate the profile.** Pointing it
at a fresh directory made Chrome hang for over ten minutes without ever
writing a screenshot. No leftover processes, but the run never completes.

The only real lever is keeping one browser process alive across many images,
which requires driving CDP — i.e. Puppeteer or Playwright. `puppeteer-core`
can attach to an already-installed Chrome, so that path at least avoids
re-downloading Chromium.

## resvg 0.47.0 vs 0.48.0

0.48.0 (2026-07-31) swapped out both halves of the text stack: shaping moved
from `rustybuzz` to `harfrust`, and font parsing from `ttf-parser` to
`skrifa` (fontations). It also fixed glyph advance calculation, `font-weight`
setting the `wght` coordinate when left at its default, absolute-transform
inheritance on text nodes, `fr` on radial gradients referenced via `href`,
`transform` on nested `<svg>`, and a `feComposite` arithmetic panic. 0.47.0
(2026-02-05) was much smaller: radial gradient focal radius (`fr`), CSS-based
font variation settings, and a `tiny-skia` bump.

Given how much of that touches text, the output was worth checking. Rendering
all three probes with both versions:

| figure | pixels differing |
|---|---|
| 01-marker-gradient-filter | 0.00% (bounding box of changes: none) |
| 02-font-weight-pattern | 0.00% (none) |
| 03-font-family-resolution | 0.00% (none) |

**Byte-identical output.** Replacing the shaping and font-parsing libraries
changed nothing visible on these figures. That is reassuring for pinning
either version, though it only covers what these probes exercise — no
variable fonts, no complex scripts, no bidi.

Speed did move, measured on `03-font-family-resolution.svg`, 20 iterations,
two passes:

| | pass 1 | pass 2 |
|---|---|---|
| resvg 0.47.0 | 27.3 ms | 26.6 ms |
| resvg 0.48.0 | 23.3 ms | 22.4 ms |

0.48.0 is roughly 15% faster and the gap reproduced across both passes.
Plausibly the `skrifa` switch, though this was not isolated further.

## Feature support

| feature | resvg | sips | Chrome |
|---|---|---|---|
| `<marker>` / `marker-end` | yes | **dropped silently** | yes |
| `font-weight` (400/700/bold) | yes | **ignored entirely** | yes |
| `font-style: italic` | **ignored** | **ignored** | yes |
| `<pattern>` | yes | yes | yes |
| `patternTransform="rotate(45)"` | yes | yes | yes |
| `linearGradient` | yes | yes | yes |
| `feGaussianBlur` | yes | yes | yes |
| output sized to viewBox | automatic | automatic | **needs `--window-size`** |

`font-weight` is the one that matters most in practice, because nothing about
the output looks broken — headings simply render at the same weight as body
text. There is no SVG-side workaround, unlike `<marker>`, which can be
replaced by an explicit `<polygon>` arrowhead.

`font-style: italic` is the one thing Chrome does that resvg does not.

## Font resolution

`03-font-family-resolution.svg`, ten declarations:

- The full stack (`-apple-system, BlinkMacSystemFont, 'Hiragino Sans', …`)
  resolves to a gothic face in all three renderers. No disagreement.
- **resvg renders all ten rows in the same gothic face**, including the
  unspecified row, `serif`, and a nonexistent family name. Its default is
  `Times New Roman`, which has no Japanese glyphs, so Japanese falls back to
  `Arial Unicode MS` regardless of what was asked for.
- sips and Chrome drop to a serif face for the unspecified row.

The practical consequence: a forgotten `font-family` is **visible** under
sips or Chrome and **invisible** under resvg. resvg does emit a warning
instead, which is more reliable than eyeballing:

```
Warning (in usvg::text:183): Fallback from Times New Roman to Arial Unicode MS.
```

`resvg --list-fonts` on the test machine found `Hiragino Sans` but neither
`Noto Sans JP` nor `Meiryo`, so those declarations fall through to the same
fallback. Results here are machine-dependent.

## Pixel differences

`python3 compare.py` on the three probes:

| figure | resvg vs sips | resvg vs chrome | sips vs chrome |
|---|---|---|---|
| 01-marker-gradient-filter | 5.6% | 5.6% | 3.3% |
| 02-font-weight-pattern | 11.0% | 11.1% | 8.6% |
| 03-font-family-resolution | 9.7% | 10.2% | 7.4% |

Note that sips scores *closer* to Chrome than resvg does on all three probes,
even though sips is the renderer dropping arrowheads and bold text. The
metric is measuring text rasterization differences — different engines, so
different hinting, spacing and antialiasing — and that noise is larger than
the features being tested.

A separate run over 42 real-world diagrams gave the same picture from the
other direction: resvg averaged 4.2% against Chrome and sips 4.5%, with resvg
closer on only 27 of 42. A 0.3 point gap is not a basis for choosing a
renderer.

**Use this table to confirm output dimensions match, then look at
`out/stack-*.png` and decide with your eyes.** The percentage is not the
answer.

## Conclusion

resvg. It is faster than sips, matches Chrome on every feature these probes
exercise except italic, and needs no arguments to honour the viewBox.
Swapping it in is a one-line change:

```diff
-sips -s format png fig.svg --out check.png
+resvg fig.svg check.png
```

Keep headless Chrome around as the tiebreaker for anything filter-heavy,
where being the actual browser is the whole point. At 1.5 s per image it is
not a loop you want to run on every edit.
