#!/usr/bin/env bash
# Fetch Japanese Wikipedia as a general-purpose corpus.
#
# The baseline dictionary wants breadth, not domain fit — domain differences
# are what the mode and user layers are for. Two things are estimated from
# this text: unigram costs, which stop mozc's lexicalised near-zero costs from
# being compared as if they were scalars, and surface bigrams, which are what
# closes the gap to a part-of-speech connection matrix without needing parts of
# speech.
#
# Measured elsewhere, single-genre corpora saturate around 80% at word level
# however much is added, so more than one shard here buys little on its own;
# the bigram, by contrast, was still climbing at 24M tokens.
#
# Extraction is deliberately crude — templates, links and tables are stripped
# with regexes rather than parsed. It is prose for counting, not a rendering.
#
# Licence: CC BY-SA 4.0 / GFDL. Nothing is committed (dict/ is gitignored) and
# only counts derived from the text are used.
set -euo pipefail

BASE="https://dumps.wikimedia.org/jawiki/latest"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/dict/corpus/jawiki"
SHARDS="${1:-1}"

mkdir -p "$OUT"

echo "Listing $BASE"
index="$OUT/.index.html"
curl -fsSL --max-time 120 "$BASE/" -o "$index"

mapfile -t files < <(
  grep -oE 'jawiki-latest-pages-articles[0-9]+\.xml-p[0-9]+p[0-9]+\.bz2' "$index" \
    | sort -u -V | head -n "$SHARDS"
)
if [[ ${#files[@]} -eq 0 ]]; then
  echo "error: no article shards found at $BASE" >&2
  exit 1
fi

for name in "${files[@]}"; do
  dest="$OUT/$name"
  if [[ -s "$dest" ]]; then
    echo "  skip  $name"
    continue
  fi
  echo "  get   $name"
  curl -fsSL --max-time 3600 "$BASE/$name" -o "$dest.part"
  mv "$dest.part" "$dest"
done

echo
echo "Extracting prose"
text="$OUT/wikipedia.txt"
python3 - "$OUT" "$text" "${files[@]}" <<'PY'
import bz2, re, sys, pathlib

out_dir, dest, *names = sys.argv[1:]

# Order matters: refs and tables go before templates, which go before links,
# so that nesting does not leave fragments behind.
DROP = [
    re.compile(r"<ref[^>]*/>"),
    re.compile(r"<ref.*?</ref>", re.S),
    re.compile(r"\{\|.*?\|\}", re.S),
    re.compile(r"<!--.*?-->", re.S),
    re.compile(r"<[^>]+>"),
]
LINK_PIPE = re.compile(r"\[\[[^\]|]*\|([^\]]*)\]\]")
LINK = re.compile(r"\[\[([^\]]*)\]\]")
EXTERNAL = re.compile(r"\[https?://\S+\s*([^\]]*)\]")
QUOTES = re.compile(r"'{2,}")
JA = re.compile(r"[ぁ-んァ-ヶ一-龠]")

def strip_templates(text):
    out, depth, index = [], 0, 0
    while index < len(text):
        if text.startswith("{{", index):
            depth += 1
            index += 2
        elif text.startswith("}}", index) and depth:
            depth -= 1
            index += 2
        else:
            if not depth:
                out.append(text[index])
            index += 1
    return "".join(out)

kept = 0
with open(dest, "w", encoding="utf-8") as sink:
    for name in names:
        with bz2.open(pathlib.Path(out_dir) / name, "rt", encoding="utf-8", errors="replace") as f:
            body, inside = [], False
            for line in f:
                if "<text" in line:
                    inside = True
                    line = line.split(">", 1)[-1]
                if not inside:
                    continue
                if "</text>" in line:
                    line = line.split("</text>")[0]
                    inside = False
                    body.append(line)
                    page = "".join(body)
                    body = []
                    page = strip_templates(page)
                    for pattern in DROP:
                        page = pattern.sub(" ", page)
                    page = LINK_PIPE.sub(r"\1", page)
                    page = LINK.sub(r"\1", page)
                    page = EXTERNAL.sub(r"\1", page)
                    page = QUOTES.sub("", page)
                    for raw in page.split("\n"):
                        s = raw.strip()
                        # Prose only: headings, list items and stubs are noise
                        # for counting and skew towards headwords.
                        if len(s) < 30 or s[0] in "=*#|:;{}[]!":
                            continue
                        if len(JA.findall(s)) < len(s) * 0.4:
                            continue
                        sink.write(s + "\n")
                        kept += 1
                else:
                    body.append(line)
print(f"lines: {kept}")
PY

chars=$(wc -m <"$text" | tr -d ' ')
echo "characters: $chars"
echo "written to: $text"
echo
echo "Licence: CC BY-SA 4.0 / GFDL (https://dumps.wikimedia.org/legal.html)"
