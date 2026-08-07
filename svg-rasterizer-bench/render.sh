#!/usr/bin/env bash
# Rasterize every figure with each available renderer into out/.
#
#   ./render.sh
#
# resvg comes from `nix develop` (or any resvg on PATH).
# sips is macOS-only. Chrome is located via CHROME_BIN or the default
# macOS install path; it is skipped when not found.
set -uo pipefail

cd "$(dirname "$0")"
OUT=out
mkdir -p "$OUT"

CHROME_BIN="${CHROME_BIN:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

have_resvg=0; command -v resvg >/dev/null 2>&1 && have_resvg=1
have_sips=0;  command -v sips  >/dev/null 2>&1 && have_sips=1
have_chrome=0; [ -x "$CHROME_BIN" ] && have_chrome=1

if [ "$have_resvg" -eq 0 ]; then
  echo "resvg not found. Run 'nix develop' first, or install resvg." >&2
fi

# Chrome screenshots the window, not the document, so the SVG's own
# width/height must be passed as --window-size. Without it the output is
# the default window size and has nothing to do with the viewBox.
svg_size() {
  local w h
  w=$(sed -n 's/.*[^-]width="\([0-9][0-9]*\)".*/\1/p' "$1" | head -1)
  h=$(sed -n 's/.*[^-]height="\([0-9][0-9]*\)".*/\1/p' "$1" | head -1)
  echo "${w:-800},${h:-600}"
}

for svg in figures/*.svg; do
  name=$(basename "$svg" .svg)
  echo "== $name"

  if [ "$have_resvg" -eq 1 ]; then
    # resvg reports unresolved fonts on stderr; keep it, that is the point.
    resvg "$svg" "$OUT/$name.resvg.png" 2> "$OUT/$name.resvg.stderr"
    if [ -s "$OUT/$name.resvg.stderr" ]; then
      echo "   resvg warnings -> $OUT/$name.resvg.stderr"
      sed 's/^/     /' "$OUT/$name.resvg.stderr" | sort -u | head -5
    fi
  fi

  if [ "$have_sips" -eq 1 ]; then
    sips -s format png "$svg" --out "$OUT/$name.sips.png" >/dev/null 2>&1
  fi

  if [ "$have_chrome" -eq 1 ]; then
    "$CHROME_BIN" --headless --disable-gpu --hide-scrollbars \
      --screenshot="$PWD/$OUT/$name.chrome.png" \
      --window-size="$(svg_size "$svg")" \
      "file://$PWD/$svg" >/dev/null 2>&1
  fi
done

echo
echo "Wrote PNGs to $OUT/. Next: python3 compare.py"
