#!/usr/bin/env bash
# Fetch a Japanese corpus for re-estimating word costs.
#
# mozc's costs cannot be used as scalars: high-frequency words get a
# lexicalised context ID and have their cost flattened to near zero, with the
# discriminating information moved into the 2672x2672 connection matrix. です
# is 0 and デス is 40. Reading those two numbers as "how likely is this word"
# is a category error, and it is why the index needs a boundary penalty at all.
#
# Estimating our own unigram costs from text is the fix. Measured elsewhere,
# 141k tokens of re-estimated scalars beat mozc's costs outright, and the
# boundary penalty stops being necessary.
#
# Nothing is committed: the corpus lands in dict/corpus/, which is gitignored.
set -euo pipefail

REPO="https://github.com/UniversalDependencies/UD_Japanese-GSD.git"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/dict/corpus/ud-japanese-gsd"

if [[ -d "$OUT/.git" ]]; then
  echo "Updating existing checkout in $OUT"
  git -C "$OUT" fetch --depth 1 origin HEAD
  git -C "$OUT" checkout FETCH_HEAD
else
  echo "Cloning UD_Japanese-GSD into $OUT"
  mkdir -p "$(dirname "$OUT")"
  template="$ROOT/dict/.empty-git-template"
  mkdir -p "$template"
  git clone --depth 1 --template="$template" "$REPO" "$OUT"
  rmdir "$template" 2>/dev/null || true
fi

echo
echo "Checked out $(git -C "$OUT" rev-parse --short HEAD)"
echo
for f in "$OUT"/*.conllu; do
  [[ -e "$f" ]] || continue
  printf '%-40s %8s lines\n' "$(basename "$f")" "$(wc -l <"$f" | tr -d ' ')"
done

echo
echo "Licence: see $OUT/LICENSE.txt"
echo "Next: swift run -c release kkc estimate"
