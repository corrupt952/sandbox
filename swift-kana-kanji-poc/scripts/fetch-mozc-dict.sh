#!/usr/bin/env bash
# Fetch the mozc OSS dictionary data.
#
# mozc is the better baseline for conversion: its reading column is hiragana
# written the way it is actually typed (助詞 は stays は, 講師 reads こうし not
# こーし), inflected forms are already expanded into their own rows, and the
# licence is BSD-3-Clause rather than GPL. See docs in the Vigilare research
# task for the measured comparison against ipadic.
#
# The repository is large, so only the data directories are checked out.
# Nothing is committed: everything lands in dict/mozc/, which is gitignored.
set -euo pipefail

REPO="https://github.com/google/mozc.git"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/dict/mozc"

# Only what the index and (later) the lattice layer need. Cone-mode
# sparse-checkout takes directories; root-level files (LICENSE) come along
# automatically.
PATHS=(
  src/data/dictionary_oss
  src/data/dictionary_manual
  src/data/single_kanji
  src/data/symbol
)

if [[ -d "$OUT/.git" ]]; then
  echo "Updating existing checkout in $OUT"
  git -C "$OUT" fetch --depth 1 origin HEAD
  git -C "$OUT" checkout FETCH_HEAD
else
  echo "Cloning mozc data into $OUT"
  mkdir -p "$(dirname "$OUT")"
  # Empty template: this is a data checkout, so the sample hooks are noise --
  # and copying them fails outright under a restricted filesystem sandbox.
  template="$ROOT/dict/.empty-git-template"
  mkdir -p "$template"
  git clone --depth 1 --filter=blob:none --sparse --template="$template" "$REPO" "$OUT"
  rmdir "$template"
  git -C "$OUT" sparse-checkout set "${PATHS[@]}"
fi

DICT="$OUT/src/data/dictionary_oss"
if [[ ! -d "$DICT" ]]; then
  echo "error: $DICT not found after checkout" >&2
  exit 1
fi

echo
echo "Checked out $(git -C "$OUT" rev-parse --short HEAD)"
echo
printf '%-42s %10s\n' "file" "lines"
for f in "$DICT"/dictionary0*.txt; do
  printf '%-42s %10s\n' "$(basename "$f")" "$(wc -l <"$f" | tr -d ' ')"
done
printf '%-42s %10s\n' "(total)" "$(cat "$DICT"/dictionary0*.txt | wc -l | tr -d ' ')"

echo
echo "Licence terms are in:"
echo "  $OUT/LICENSE                 (BSD-3-Clause)"
echo "  $DICT/README.txt             (IPAdic / Okinawa dictionary terms)"
echo
echo "Next: swift run -c release kkc build --format mozc"
