#!/usr/bin/env bash
# Measure per-image wall-clock time for each renderer.
#
#   ./bench.sh [iterations]
#
# The interesting row is Chrome against about:blank: if rendering an empty
# page costs the same as rendering the SVG, the time is process startup and
# no amount of flag tuning will reduce it.
set -uo pipefail

cd "$(dirname "$0")"
N="${1:-5}"
SVG="figures/01-marker-gradient-filter.svg"
OUT=out
mkdir -p "$OUT"

CHROME_BIN="${CHROME_BIN:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

now() { python3 -c 'import time;print(time.time())'; }
report() { python3 -c "print(f'{\"$1\":<42} {($3-$2)/$4*1000:7.0f} ms/image')"; }

if command -v resvg >/dev/null 2>&1; then
  t0=$(now)
  for _ in $(seq "$N"); do resvg "$SVG" "$OUT/bench.png" >/dev/null 2>&1; done
  report "resvg" "$t0" "$(now)" "$N"
fi

if command -v sips >/dev/null 2>&1; then
  t0=$(now)
  for _ in $(seq "$N"); do sips -s format png "$SVG" --out "$OUT/bench.png" >/dev/null 2>&1; done
  report "sips" "$t0" "$(now)" "$N"
fi

if [ -x "$CHROME_BIN" ]; then
  BASE=(--headless --disable-gpu --hide-scrollbars)
  # Flags people usually reach for when trying to make headless Chrome boot faster.
  SLIM=(--disable-extensions --disable-background-networking --disable-sync
        --disable-default-apps --no-first-run --disable-component-update
        --disable-client-side-phishing-detection --metrics-recording-only --mute-audio
        --disable-backgrounding-occluded-windows --disable-renderer-backgrounding
        --disable-features=Translate,MediaRouter,OptimizationHints)

  chrome_run() {
    local label="$1" url="$2"; shift 2
    local t0; t0=$(now)
    for _ in $(seq "$N"); do
      "$CHROME_BIN" "$@" --screenshot="$PWD/$OUT/bench.png" --window-size=480,200 "$url" >/dev/null 2>&1
    done
    report "$label" "$t0" "$(now)" "$N"
  }

  chrome_run "chrome (baseline flags)"        "file://$PWD/$SVG" "${BASE[@]}"
  chrome_run "chrome (baseline, about:blank)" "about:blank"      "${BASE[@]}"
  chrome_run "chrome (+ slim flags)"          "file://$PWD/$SVG" "${BASE[@]}" "${SLIM[@]}"
  chrome_run "chrome (+ slim, about:blank)"   "about:blank"      "${BASE[@]}" "${SLIM[@]}"
fi

cat <<'NOTE'

Note: do not try --user-data-dir to "isolate the profile". Creating a fresh
profile made Chrome hang for over ten minutes on macOS during this
investigation, with no screenshot ever produced.
NOTE
