#!/usr/bin/env bash
# Fetch the mecab-ipadic source files (CSV lexicon + connection cost matrix)
# and transcode them from EUC-JP to UTF-8.
#
# Nothing is committed: the language resources land in dict/src/, which is
# gitignored. The distribution story for a real product is the same shape --
# ship code, fetch the lexicon at build/first-run time.
set -euo pipefail

BASE="https://raw.githubusercontent.com/taku910/mecab/master/mecab-ipadic"
OUT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/dict/src"

# ipadic 2.7.0-20070801 file set (frozen since 2007).
CSV_FILES=(
  Adj.csv Adnominal.csv Adverb.csv Auxil.csv Conjunction.csv Filler.csv
  Interjection.csv Noun.adjv.csv Noun.adverbal.csv Noun.csv Noun.demonst.csv
  Noun.nai.csv Noun.name.csv Noun.number.csv Noun.org.csv Noun.others.csv
  Noun.place.csv Noun.proper.csv Noun.verbal.csv Others.csv Postp-col.csv
  Postp.csv Prefix.csv Suffix.csv Symbol.csv Verb.csv
)
DEF_FILES=(matrix.def char.def unk.def)

mkdir -p "$OUT"

fetch() {
  local name="$1"
  local dest="$OUT/$name"
  if [[ -s "$dest" ]]; then
    echo "  skip  $name (already present)"
    return
  fi
  echo "  get   $name"
  curl -fsSL "$BASE/$name" -o "$dest.eucjp"
  # ipadic ships as EUC-JP; everything downstream assumes UTF-8.
  iconv -f EUC-JP -t UTF-8 "$dest.eucjp" >"$dest"
  rm -f "$dest.eucjp"
}

echo "Fetching mecab-ipadic into $OUT"
for f in "${CSV_FILES[@]}" "${DEF_FILES[@]}"; do
  fetch "$f"
done

echo
echo "Done. $(ls -1 "$OUT" | wc -l | tr -d ' ') files, $(du -sh "$OUT" | cut -f1) total."
echo "Next: swift run -c release kkc build"
